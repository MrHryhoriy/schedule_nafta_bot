# bot.rb
require 'telegram/bot'
require 'dotenv/load'
require 'json'
require 'net/http'
require 'uri'
require 'nokogiri'
require 'cgi'
require 'date'

# =====================================
# Константи та шляхи до файлів
# =====================================

TOKEN = ENV['BOT_TOKEN'] || ENV['TELEGRAM_BOT_TOKEN']
BASE_URL = "https://dekanat.nung.edu.ua/cgi-bin/timetable.cgi"

SCHEDULE_FILE     = "schedule.json"
USER_GROUPS_FILE  = "user_groups.json"
GROUPS_FILE       = "groups.json"
GROUP_IDS_FILE    = "group_ids.json"

# Стандартні часи пар
LESSON_DEFAULT_TIMES = {
  "1" => "08:00 - 09:20",
  "2" => "09:30 - 10:50",
  "3" => "11:00 - 12:20",
  "4" => "12:50 - 14:10",
  "5" => "14:20 - 15:40",
  "6" => "15:50 - 17:10",
  "7" => "17:20 - 18:40",
  "8" => "18:50 - 20:10"
}.freeze

# =====================================
# Робота з JSON
# =====================================

def load_json_hash(path)
  return {} unless File.exist?(path)
  JSON.parse(File.read(path))
rescue JSON::ParserError
  {}
end

def load_json_array(path)
  return [] unless File.exist?(path)
  JSON.parse(File.read(path))
rescue JSON::ParserError
  []
end

def save_json(path, data)
  File.write(path, JSON.pretty_generate(data))
end

SCHEDULE       = load_json_hash(SCHEDULE_FILE)     # group_name => date_str => {...}
USER_GROUPS    = load_json_hash(USER_GROUPS_FILE)  # chat_id_str => group_name
GROUPS         = load_json_array(GROUPS_FILE)      # ["ПЗС-23-1", ...]
GROUP_SITE_IDS = load_json_hash(GROUP_IDS_FILE)    # group_name => "-1911"
USER_STATE     = {}                                # chat_id_str => "await_group_query" і т.п.

def save_schedule(hash = SCHEDULE)
  save_json(SCHEDULE_FILE, hash)
end

def save_user_groups(hash = USER_GROUPS)
  save_json(USER_GROUPS_FILE, hash)
end

def save_group_site_ids(hash = GROUP_SITE_IDS)
  save_json(GROUP_IDS_FILE, hash)
end

# =====================================
# Допоміжні функції для дат
# =====================================

def weekday_key(date)
  case date.wday
  when 1 then 'mon'
  when 2 then 'tue'
  when 3 then 'wed'
  when 4 then 'thu'
  when 5 then 'fri'
  when 6 then 'sat'
  when 0 then 'sun'
  end
end

def weekday_uk(date)
  case date.wday
  when 1 then 'Понеділок'
  when 2 then 'Вівторок'
  when 3 then 'Середа'
  when 4 then 'Четвер'
  when 5 then 'Пʼятниця'
  when 6 then 'Субота'
  when 0 then 'Неділя'
  end
end

# форма для "на понеділок / на середу / ..."
def weekday_uk_acc(date)
  case date.wday
  when 1 then 'понеділок'
  when 2 then 'вівторок'
  when 3 then 'середу'
  when 4 then 'четвер'
  when 5 then 'пʼятницю'
  when 6 then 'суботу'
  when 0 then 'неділю'
  end
end

DAY_ALIASES = {
  'mon' => %w[mon monday пн пон понеділок],
  'tue' => %w[tue tuesday вт вів вівторок],
  'wed' => %w[wed wednesday ср сер середа],
  'thu' => %w[thu thursday чт чет четвер],
  'fri' => %w[fri friday пт пʼт п'т пʼят пʼятниця пятниця],
  'sat' => %w[sat saturday сб суб субота],
  'sun' => %w[sun sunday нд нед неділя]
}.freeze

def normalize_day_key(text)
  return nil unless text
  down = text.strip.downcase
  DAY_ALIASES.each do |key, variants|
    return key if variants.include?(down)
  end
  nil
end

def date_for_weekday_in_current_week(day_key, base_date = Date.today)
  target_wday =
    case day_key
    when 'mon' then 1
    when 'tue' then 2
    when 'wed' then 3
    when 'thu' then 4
    when 'fri' then 5
    when 'sat' then 6
    when 'sun' then 0
    else
      return nil
    end

  delta = target_wday - base_date.wday
  base_date + delta
end

# =====================================
# Побажання на день
# =====================================

DAILY_WISHES = [
  "Бажаю тобі сьогодні легких пар і вільних віконець! 🎓",
  "Нехай усі пари сьогодні пройдуть швидко й корисно! 📚",
  "Успішного дня та хорошого настрою! ✨",
  "Хай викладачі будуть добрими, а конспекти — зрозумілими! 📝",
  "Нехай сьогоднішній день принесе тільки приємні сюрпризи! 😊"
].freeze

def random_daily_wish
  DAILY_WISHES.sample
end

# =====================================
# Форматування інформаційних блоків пар
# =====================================

def format_info_block_html(info)
  # спочатку замінимо " | " на нові рядки
  normalized = info.to_s.gsub(/\s*\|\s*/, "\n")

  lines = []

  normalized.split(/\n+/).each do |ln|
    clean = ln.strip
    next if clean.empty?

    # окремий рядок "дистанційно" — робимо хатку + жирний текст
    if clean =~ /\Aдистанційно\z/i
      lines << "🏠 <b>дистанційно</b>"
    else
      lines << clean
    end
  end

  lines.join("\n")
end

# =====================================
# Форматування розкладу
# =====================================

def schedule_for_day(schedule, group_name, date)
  date_str   = date.strftime('%Y-%m-%d')
  group_data = schedule[group_name] || {}
  day_info   = group_data[date_str]

  header = "Розклад академічної групи #{group_name} на #{weekday_uk_acc(date)}, #{date.strftime('%d.%m.%Y')} р."

  unless day_info && day_info['lessons'] && !day_info['lessons'].empty?
    return "#{header}\n\nПар не знайдено."
  end

  # Кладемо всі заняття в слоти по номерах пар
  slots = {} # num => [info_block1, info_block2, ...]

  day_info['lessons'].each do |line|
    if line =~ /^(\d+)\.\s*\[(.*?)\]\s*(.*)$/m
      num  = Regexp.last_match(1)            # номер пари
      info = Regexp.last_match(3).to_s.strip # текст після часу (може бути з \n)
      slots[num] ||= []
      slots[num] << info unless info.empty?
    else
      slots["0"] ||= []
      slots["0"] << line
    end
  end

  lines = []
  lines << header
  lines << ""

  (1..8).each do |n|
    num      = n.to_s
    time_str = LESSON_DEFAULT_TIMES[num] || ""
    blocks   = slots[num] || []

    # заголовок пари
    lines << "#{num}. #{time_str}"

    unless blocks.empty?
      blocks.each_with_index do |info_block, idx|
        lines << "" if idx > 0

        formatted = format_info_block_html(info_block)
        lines << formatted unless formatted.empty?
      end
    end

    lines << "" # порожній рядок між парами
  end

  lines.join("\n")
end

def schedule_for_week(schedule, group_name, base_date = Date.today)
  # Тиждень починається з неділі
  week_start = base_date - base_date.wday
  texts = []

  7.times do |i|
    day = week_start + i
    texts << schedule_for_day(schedule, group_name, day)
  end

  texts.join("\n\n" + "-" * 32 + "\n\n")
end

# =====================================
# Парсинг HTML розкладу з сайту IFNTUNG
# =====================================

def td_to_lines(td)
  html = td.inner_html

  html.split(/<br\s*\/?>/i).map do |fragment|
    frag_doc = Nokogiri::HTML.fragment(fragment)

    # для всіх <a> — беремо повний href замість обрізаного тексту
    frag_doc.css('a').each do |a|
      href = a['href'].to_s.strip
      next if href.empty?
      a.content = href
    end

    frag_doc.text.gsub(/\s+/, ' ').strip
  end.reject(&:empty?)
end

def parse_group_schedule(html)
  doc = Nokogiri::HTML(html)
  result = {}

  doc.css('div.col-print-6 > h4').each do |h4|
    text = h4.text.strip

    # Дата у форматі dd.mm.yyyy
    unless text =~ /(\d{2}\.\d{2}\.\d{4})/
      next
    end
    date_str = Regexp.last_match(1)

    date = begin
      Date.strptime(date_str, '%d.%m.%Y')
    rescue ArgumentError
      nil
    end
    next unless date

    parent = h4.parent
    table  = parent.at_css('table')
    next unless table

    lessons = []

    table.css('tr').each do |tr|
      tds_lines = tr.css('td').map { |td| td_to_lines(td) } # масив масивів
      next if tds_lines.empty? || tds_lines.all? { |arr| arr.all?(&:empty?) }

      num_lines  = tds_lines[0] || []
      time_lines = tds_lines[1] || []

      num  = (num_lines[0]  || '').strip
      time = (time_lines[0] || '').strip

      info_lines = []
      if tds_lines.length > 2
        tds_lines[2..-1].each do |arr|
          info_lines.concat(arr)
        end
      end

      info = info_lines.join("\n").strip

      next if num.empty? && info.empty? && time.empty?

      line = "#{num}. [#{time}] #{info}".strip
      lessons << line
    end

    next if lessons.empty?

    key = date.strftime('%Y-%m-%d')
    result[key] = {
      "weekday" => weekday_key(date),
      "lessons" => lessons
    }
  end

  result
end

# =====================================
# Кодування CP1251 та HTTP
# =====================================

def percent_encode_cp1251(str)
  bytes = str.to_s.encode("Windows-1251", invalid: :replace, undef: :replace).bytes
  bytes.map { |b| "%%%02X" % b }.join
end

def post_cp1251(url, params)
  uri = URI(url)

  body = params.map do |k, v|
    key = URI.encode_www_form_component(k.to_s)   # ключі — ASCII
    val = percent_encode_cp1251(v.to_s)           # значення — CP1251 → %XX
    "#{key}=#{val}"
  end.join("&")

  http = Net::HTTP.new(uri.host, uri.port)
  http.use_ssl = (uri.scheme == "https")

  req = Net::HTTP::Post.new(uri.request_uri)
  req["Content-Type"] = "application/x-www-form-urlencoded"
  req.body = body

  http.request(req)
end

# =====================================
# Витягнути ID групи з HTML розкладу
# =====================================

def extract_group_id_from_html(html)
  doc = Nokogiri::HTML(html)
  link = doc.at_css("h4 a[title*='Постійне посилання']")
  return nil unless link

  href = link["href"]
  return nil unless href

  begin
    uri   = URI(href)
    query = CGI.parse(uri.query || "")
    if query["group"] && !query["group"].empty?
      return query["group"].first
    end
  rescue URI::InvalidURIError
    # якщо URL кривий — просто впадемо в regex нижче
  end

  href[/[?&]group=([^&]+)/, 1]
end

# =====================================
# Отримати ID групи за назвою
# =====================================

def fetch_group_id_for_name(group_name)
  url = "#{BASE_URL}?n=700"

  response = post_cp1251(url, {
    "group" => group_name,
    "sdate" => "",
    "edate" => ""
  })

  unless response.is_a?(Net::HTTPSuccess)
    warn "[fetch_group_id_for_name] HTTP #{response.code} для #{group_name}"
    return nil
  end

  body = response.body.force_encoding("Windows-1251")
                     .encode("UTF-8", invalid: :replace, undef: :replace)

  group_id = extract_group_id_from_html(body)

  if group_id.nil? || group_id.empty?
    warn "[fetch_group_id_for_name] Не знайшов id у HTML для #{group_name}"
  else
    puts "[fetch_group_id_for_name] #{group_name} → #{group_id}"
  end

  group_id
end

# =====================================
# Отримати HTML розкладу за ID групи
# =====================================

def fetch_group_html_by_id(group_id)
  uri = URI("#{BASE_URL}?n=700&group=#{CGI.escape(group_id.to_s)}")
  res = Net::HTTP.get_response(uri)
  unless res.is_a?(Net::HTTPSuccess)
    raise "HTTP #{res.code} при отриманні розкладу для group=#{group_id}"
  end

  res.body.force_encoding("Windows-1251")
          .encode("UTF-8", invalid: :replace, undef: :replace)
end

# =====================================
# Оновлення розкладу з сайту
# =====================================

def update_schedule_from_site(group_name)
  group_id = GROUP_SITE_IDS[group_name]

  if group_id.nil? || group_id.to_s.strip.empty?
    group_id = fetch_group_id_for_name(group_name)
    unless group_id
      msg = "Не вдалося отримати id групи #{group_name} із сайту"
      puts msg
      return msg
    end

    GROUP_SITE_IDS[group_name] = group_id
    save_group_site_ids(GROUP_SITE_IDS)
  end

  html = fetch_group_html_by_id(group_id)
  daily_schedule = parse_group_schedule(html)

  if daily_schedule.empty?
    msg = "На сайті не знайдено пар для групи #{group_name} (id #{group_id})"
    puts msg
    return msg
  end

  SCHEDULE[group_name] ||= {}
  SCHEDULE[group_name].merge!(daily_schedule)
  save_schedule(SCHEDULE)

  msg = "Розклад для #{group_name} (id #{group_id}) оновлено, днів: #{daily_schedule.size}"
  puts msg
  msg
end

# =====================================
# Оновлення розкладу "на вимогу"
# =====================================

def refresh_group_schedule_on_demand(group_name)
  return if group_name.nil? || group_name.to_s.strip.empty?

  msg = update_schedule_from_site(group_name)
  puts "[ON-DEMAND UPDATE] #{msg}"
rescue => e
  puts "[ON-DEMAND UPDATE] ERROR #{e.class}: #{e.message}"
end

# =====================================
# (Опційне) Автооновлення — не використовується
# =====================================

def start_auto_update
  Thread.new do
    loop do
      begin
        puts "[AUTO-UPDATE] Старт оновлення: #{Time.now}"

        GROUPS.each do |group_name|
          res = update_schedule_from_site(group_name)
          puts "[AUTO-UPDATE] #{group_name}: #{res}"
          sleep 1
        end

      rescue => e
        puts "[AUTO-UPDATE] Помилка: #{e.class} - #{e.message}"
      end

      sleep 60 * 60
    end
  end
end

# НЕ викликаємо start_auto_update – оновлюємо тільки на вимогу

# =====================================
# Хелпери для Telegram
# =====================================

def user_group(chat_id)
  USER_GROUPS[chat_id.to_s]
end

def set_user_group(chat_id, group_name)
  USER_GROUPS[chat_id.to_s] = group_name
  save_user_groups
end

def find_groups_by_query(query)
  q = query.to_s.strip.downcase
  return [] if q.empty?

  GROUPS.select { |g| g.downcase.include?(q) }
end

def build_groups_keyboard(groups)
  Telegram::Bot::Types::ReplyKeyboardMarkup.new(
    keyboard: groups.each_slice(3).map { |slice| slice.map { |g| Telegram::Bot::Types::KeyboardButton.new(text: g) } },
    resize_keyboard: true,
    one_time_keyboard: true
  )
end

def main_menu_keyboard(has_group = true)
  if has_group
    Telegram::Bot::Types::ReplyKeyboardMarkup.new(
      keyboard: [
        [Telegram::Bot::Types::KeyboardButton.new(text: "Група")],
        [
          Telegram::Bot::Types::KeyboardButton.new(text: "Розклад"),
          Telegram::Bot::Types::KeyboardButton.new(text: "Сьогодні")
        ],
        [Telegram::Bot::Types::KeyboardButton.new(text: "Залишок дня")],
        [Telegram::Bot::Types::KeyboardButton.new(text: "Допомога")]
      ],
      resize_keyboard: true
    )
  else
    Telegram::Bot::Types::ReplyKeyboardMarkup.new(
      keyboard: [
        [Telegram::Bot::Types::KeyboardButton.new(text: "Група")],
        [Telegram::Bot::Types::KeyboardButton.new(text: "Міні-посібник для новачків")]
      ],
      resize_keyboard: true
    )
  end
end

def group_menu_keyboard(has_group)
  if has_group
    # Користувач уже має групу
    Telegram::Bot::Types::ReplyKeyboardMarkup.new(
      keyboard: [
        [Telegram::Bot::Types::KeyboardButton.new(text: "Змінити групу")],
        [Telegram::Bot::Types::KeyboardButton.new(text: "Вийти з групи")],
        [Telegram::Bot::Types::KeyboardButton.new(text: "⬅️ Назад")]
      ],
      resize_keyboard: true
    )
  else
    # Користувач ще НЕ має групи
    Telegram::Bot::Types::ReplyKeyboardMarkup.new(
      keyboard: [
        [Telegram::Bot::Types::KeyboardButton.new(text: "Знайти групу")],
        [Telegram::Bot::Types::KeyboardButton.new(text: "⬅️ Назад")]
      ],
      resize_keyboard: true
    )
  end
end

def group_after_exit_keyboard
  Telegram::Bot::Types::ReplyKeyboardMarkup.new(
    keyboard: [
      [Telegram::Bot::Types::KeyboardButton.new(text: "Знайти групу")],
      [Telegram::Bot::Types::KeyboardButton.new(text: "⬅️ Назад")]
    ],
    resize_keyboard: true
  )
end

def search_group_keyboard
  Telegram::Bot::Types::ReplyKeyboardMarkup.new(
    keyboard: [
      [Telegram::Bot::Types::KeyboardButton.new(text: "⬅️ Назад")]
    ],
    resize_keyboard: true
  )
end

def schedule_inline_keyboard
  Telegram::Bot::Types::InlineKeyboardMarkup.new(
    inline_keyboard: [
      [
        Telegram::Bot::Types::InlineKeyboardButton.new(text: "Пн", callback_data: "sched_mon"),
        Telegram::Bot::Types::InlineKeyboardButton.new(text: "Вт", callback_data: "sched_tue"),
        Telegram::Bot::Types::InlineKeyboardButton.new(text: "Ср", callback_data: "sched_wed"),
        Telegram::Bot::Types::InlineKeyboardButton.new(text: "Чт", callback_data: "sched_thu"),
        Telegram::Bot::Types::InlineKeyboardButton.new(text: "Пт", callback_data: "sched_fri"),
        Telegram::Bot::Types::InlineKeyboardButton.new(text: "Сб", callback_data: "sched_sat"),
        Telegram::Bot::Types::InlineKeyboardButton.new(text: "Нд", callback_data: "sched_sun")
      ],
      [
        Telegram::Bot::Types::InlineKeyboardButton.new(text: "⬅️ Назад", callback_data: "sched_back")
      ]
    ]
  )
end

def build_start_text(name, current)
  lines = []
  if current
    lines << "Привіт, #{name}! 👋"
    lines << "Я твій розклад ІФНТУНГ."
    lines << ""
    lines << "Ти зараз відмічений як студент групи: #{current}."
    lines << ""
    lines << "Для перегляду розкладу:"
    lines << "• натисни «Розклад», щоб вибрати день тижня;"
    lines << "• якщо поспішаєш на пари — просто натисни «Сьогодні», щоб швидко побачити пари на сьогодні."
    lines << ""
    lines << random_daily_wish
  else
    lines << "Привіт, #{name}! 👋"
    lines << "Я твій розклад ІФНТУНГ."
    lines << random_daily_wish
    lines << ""
    lines << "Ой, щось я тебе не бачу в жодній групі… 🙈"
    lines << "Будь ласка, вибери свою групу в розділі «Група» (або скористайся командами) нижче."
    lines << ""
    lines << "Долучайся до університетської родини вже сьогодні — за вас, за нас, за Нафту і Газ! 🛢️🎓"
  end
  lines.join("\n")
end

def build_help_text(current)
  lines = []
  lines << "🤖 Невеликий посібник для новачків:"
  lines << ""

  if current
    lines << "Зараз ти відмічений як студент групи: #{current}."
  else
    lines << "Поки що ти не вибрав групу — без цього розклад не працюватиме повністю."
  end

  lines << ""
  lines << "1. Як обрати або змінити групу:"
  lines << "   • Натисни кнопку «Група»."
  lines << "   • Обери «Знайти групу» і введи повну назву або абревіатуру ООП."
  lines << "   • Якщо ти магістр або заочно навчаєшся — додавай м/з після ООП."
  lines << ""
  lines << "2. Основні кнопки:"
  lines << "   • «Розклад» — показує розклад за днями тижня (Пн–Нд)."
  lines << "   • «Сьогодні» — швидкий розклад-експрес на поточний день."
  lines << "   • «Залишок дня» — показує тільки ті пари, які ще залишились сьогодні."
  lines << ""
  lines << "3. Корисні команди:"
  lines << "   /start   — перезапустити привітання"
  lines << "   /menu    — показати головне меню"
  lines << "   /mygroup — показати поточну групу"
  lines << "   /group <назва> — знайти і вибрати групу через команду"
  lines << ""
  lines << "Якщо щось пішло не так — просто надішли /start, і ми почнемо спочатку 🙂"

  lines.join("\n")
end

# =====================================
# Запуск Telegram-бота
# =====================================

raise "BOT_TOKEN не заданий у .env" unless TOKEN && !TOKEN.empty?

Telegram::Bot::Client.run(TOKEN) do |bot|
  puts "Bot started..."

  bot.listen do |update|
    begin
      case update
      when Telegram::Bot::Types::CallbackQuery
        cq      = update
        chat_id = cq.message.chat.id
        data    = cq.data.to_s
        group   = user_group(chat_id)

        case data
        when "sched_mon", "sched_tue", "sched_wed", "sched_thu",
             "sched_fri", "sched_sat", "sched_sun"
          day_key =
            case data
            when "sched_mon" then "mon"
            when "sched_tue" then "tue"
            when "sched_wed" then "wed"
            when "sched_thu" then "thu"
            when "sched_fri" then "fri"
            when "sched_sat" then "sat"
            when "sched_sun" then "sun"
            end

          if group.nil?
            bot.api.edit_message_text(
              chat_id:    chat_id,
              message_id: cq.message.message_id,
              text:       "Спочатку обери свою групу кнопкою «Група».",
              reply_markup: nil
            )
          else
            refresh_group_schedule_on_demand(group)
            date = date_for_weekday_in_current_week(day_key, Date.today)
            txt  = schedule_for_day(SCHEDULE, group, date)
            bot.api.edit_message_text(
              chat_id:    chat_id,
              message_id: cq.message.message_id,
              text:       txt,
              reply_markup: schedule_inline_keyboard,
              parse_mode: 'HTML'
            )
          end

          bot.api.answer_callback_query(callback_query_id: cq.id)

        when "sched_back"
          name    = cq.from&.first_name || "студенте"
          current = group
          txt     = build_start_text(name, current)

          # 1) Повідомлення, що користувач повернувся
          bot.api.send_message(
            chat_id: chat_id,
            text: "Ви повернулися до головного меню."
          )

          # 2) Стартове повідомлення + звичайна клавіатура
          bot.api.send_message(
            chat_id: chat_id,
            text: txt,
            reply_markup: main_menu_keyboard(!current.nil?)
          )

          bot.api.answer_callback_query(callback_query_id: cq.id)

        else
          bot.api.answer_callback_query(callback_query_id: cq.id)
        end

      when Telegram::Bot::Types::Message
        msg      = update
        chat_id  = msg.chat.id
        text_raw = msg.text.to_s
        text     = text_raw.strip
        state    = USER_STATE[chat_id.to_s]

        # Якщо користувач вибрав групу із списку груп (reply-клавіатура)
        if GROUPS.include?(text)
          chosen = text
          set_user_group(chat_id, chosen)
          USER_STATE.delete(chat_id.to_s)
          bot.api.send_message(
            chat_id: chat_id,
            text: "Вітаю, ви успішно знайшли свою групу!\nВаша група — #{chosen}.",
            reply_markup: group_menu_keyboard(true)
          )
          next
        end

        # Обробка кнопок (не команд)
        unless text.start_with?("/")
          case text
          when "Група"
            current = user_group(chat_id)
            msg_text =
              if current
                "Ти зараз відмічений як студент групи: #{current}.\n\n" \
                "Можеш змінити свою групу або вийти з поточної."
              else
                "Поки що ти не вибрав групу.\n\n" \
                "Натисни «Знайти групу», щоб знайти свою групу."
              end

            USER_STATE.delete(chat_id.to_s)
            bot.api.send_message(
              chat_id: chat_id,
              text: msg_text,
              reply_markup: group_menu_keyboard(!current.nil?)
            )
            next

          when "Знайти групу", "Змінити групу"
            USER_STATE[chat_id.to_s] = "await_group_query"

            instructions_text = <<~TXT
              Для того, щоб знайти свою групу, вкажіть повну назву групи.

              Якщо ви не можете знайти її, вкажіть абревіатуру ООП, на яку вступили.
              Якщо ви магістр або заочно навчаєтесь, вкажіть після ООП букви м/з.

              Після вказаних даних, знизу вам буде надано клавіатуру для вибору своєї групи.
            TXT

            bot.api.send_message(
              chat_id: chat_id,
              text: instructions_text,
              reply_markup: search_group_keyboard
            )
            next

          when "Вийти з групи"
            current = user_group(chat_id)

            if current
              USER_GROUPS.delete(chat_id.to_s)
              save_user_groups
              USER_STATE.delete(chat_id.to_s)
              bot.api.send_message(
                chat_id: chat_id,
                text: "Ти вийшов з групи #{current}.\n\n" \
                      "Можеш знайти нову групу або повернутися назад у головне меню.",
                reply_markup: group_after_exit_keyboard
              )
            else
              bot.api.send_message(
                chat_id: chat_id,
                text: "Ти ще не обрав жодної групи 🙂",
                reply_markup: group_after_exit_keyboard
              )
            end
            next

          when "⬅️ Назад"
            USER_STATE.delete(chat_id.to_s)
            current = user_group(chat_id)
            name    = msg.from&.first_name || "студенте"
            txt     = build_start_text(name, current)

            bot.api.send_message(
              chat_id: chat_id,
              text: txt,
              reply_markup: main_menu_keyboard(!current.nil?)
            )
            next

          when "Розклад"
            current = user_group(chat_id)
            if current.nil?
              bot.api.send_message(
                chat_id: chat_id,
                text: "Спочатку обери свою групу кнопкою «Група».",
                reply_markup: main_menu_keyboard(false)
              )
            else
              refresh_group_schedule_on_demand(current)

              today = Date.today
              week_start = today - today.wday
              week_end   = week_start + 6

              header   = "📅 Розклад групи #{current} на тиждень: #{week_start.strftime('%d.%m.%Y')} — #{week_end.strftime('%d.%m.%Y')}"
              day_text = schedule_for_day(SCHEDULE, current, today)

              # 1) Заголовок тижня + сховати клаву
              bot.api.send_message(
                chat_id: chat_id,
                text:  header,
                reply_markup: Telegram::Bot::Types::ReplyKeyboardRemove.new(remove_keyboard: true)
              )

              # 2) Розклад на сьогодні + inline-кнопки днів
              bot.api.send_message(
                chat_id: chat_id,
                text: day_text,
                reply_markup: schedule_inline_keyboard,
                parse_mode: 'HTML'
              )
            end
            next

          when "Сьогодні"
            current = user_group(chat_id)
            if current.nil?
              bot.api.send_message(
                chat_id: chat_id,
                text: "Спочатку обери свою групу кнопкою «Група».",
                reply_markup: main_menu_keyboard(false)
              )
            else
              refresh_group_schedule_on_demand(current)

              today     = Date.today
              today_str = today.strftime('%d.%m.%Y')

              # 1) експрес-повідомлення
              intro_text = "Тримай, друже, твій швидкий розклад-експрес на сьогоднішній день, #{today_str}. Удачі на парах."
              bot.api.send_message(
                chat_id: chat_id,
                text: intro_text
              )

              # 2) розклад за макетом + кнопка Назад
              day_text = schedule_for_day(SCHEDULE, current, today)

              back_keyboard = Telegram::Bot::Types::ReplyKeyboardMarkup.new(
                keyboard: [
                  [Telegram::Bot::Types::KeyboardButton.new(text: "⬅️ Назад")]
                ],
                resize_keyboard: true
              )

              bot.api.send_message(
                chat_id: chat_id,
                text: day_text,
                reply_markup: back_keyboard,
                parse_mode: 'HTML'
              )
            end
            next

          when "Залишок дня"
            current = user_group(chat_id)
            if current.nil?
              bot.api.send_message(
                chat_id: chat_id,
                text: "Спочатку обери свою групу кнопкою «Група».",
                reply_markup: main_menu_keyboard(false)
              )
            else
              refresh_group_schedule_on_demand(current)

              now   = Time.now
              today = Date.today
              lessons_today = SCHEDULE.dig(current, today.strftime('%Y-%m-%d'), 'lessons') || []

              if lessons_today.empty?
                bot.api.send_message(
                  chat_id: chat_id,
                  text: "На сьогодні пар не заплановано. Відпочивай 😌",
                  reply_markup: main_menu_keyboard(true)
                )
                next
              end

              remaining = []
              lessons_today.each do |line|
                if line =~ /^(\d+)\.\s*\[(.+?)\]\s*(.*)$/m
                  time = Regexp.last_match(2)

                  if time =~ /(\d{2}:\d{2})\D?(\d{2}:\d{2})/
                    end_time = Regexp.last_match(2)
                    end_h, end_m = end_time.split(':').map(&:to_i)
                    end_obj = Time.new(now.year, now.month, now.day, end_h, end_m, 0)

                    remaining << line if now < end_obj
                  else
                    remaining << line
                  end
                end
              end

              if remaining.empty?
                bot.api.send_message(
                  chat_id: chat_id,
                  text: "На сьогодні пари вже завершились. Можна відпочити 😌",
                  reply_markup: main_menu_keyboard(true)
                )
              else
                back_keyboard = Telegram::Bot::Types::ReplyKeyboardMarkup.new(
                  keyboard: [
                    [Telegram::Bot::Types::KeyboardButton.new(text: "⬅️ Назад")]
                  ],
                  resize_keyboard: true
                )

                blocks = []

                remaining.each do |line|
                  if line =~ /^(\d+)\.\s*\[(.+?)\]\s*(.*)$/m
                    num  = Regexp.last_match(1)
                    time = Regexp.last_match(2)
                    info = Regexp.last_match(3).to_s.strip

                    time_str = LESSON_DEFAULT_TIMES[num] || time

                    block_lines = []
                    block_lines << "#{num}. #{time_str}"

                    formatted_info = format_info_block_html(info)
                    block_lines << "" unless formatted_info.empty?
                    block_lines << formatted_info unless formatted_info.empty?

                    blocks << block_lines.join("\n")
                  else
                    formatted = format_info_block_html(line)
                    blocks << formatted
                  end
                end

                msg_text = "🕓 Пари, які залишились на сьогодні (#{today.strftime('%d.%m.%Y')}):\n\n"
                msg_text += blocks.join("\n\n")

                bot.api.send_message(
                  chat_id: chat_id,
                  text: msg_text,
                  reply_markup: back_keyboard,
                  parse_mode: 'HTML'
                )
              end
            end
            next

          when "Допомога", "Міні-посібник для новачків"
            current   = user_group(chat_id)
            help_text = build_help_text(current)

            bot.api.send_message(
              chat_id: chat_id,
              text: help_text
            )
            next
          end

          # режим пошуку групи
          if state == "await_group_query"
            query   = text
            matches = find_groups_by_query(query)

            if matches.empty?
              bot.api.send_message(
                chat_id: chat_id,
                text: "За запитом «#{query}» груп не знайдено. Спробуй уточнити назву."
              )
            elsif matches.size == 1
              chosen = matches.first
              set_user_group(chat_id, chosen)
              USER_STATE.delete(chat_id.to_s)
              bot.api.send_message(
                chat_id: chat_id,
                text: "Вітаю, ви успішно знайшли свою групу!\nВаша група — #{chosen}.",
                reply_markup: group_menu_keyboard(true)
              )
            else
              kb = build_groups_keyboard(matches.take(30))
              bot.api.send_message(
                chat_id: chat_id,
                text: "Обери свою групу зі списку:",
                reply_markup: kb
              )
            end

            next
          end
        end

        # Далі — текстові команди (/start, /today, /week, ...)
        case text
        when %r{\A/start\b}i
          USER_STATE.delete(chat_id.to_s)
          current = user_group(chat_id)
          name    = msg.from&.first_name || "студенте"

          bot.api.send_message(
            chat_id: chat_id,
            text: build_start_text(name, current),
            reply_markup: main_menu_keyboard(!current.nil?)
          )

        when %r{\A/menu\b}i
          USER_STATE.delete(chat_id.to_s)
          current = user_group(chat_id)
          text_menu =
            if current
              "Головне меню.\nТвоя поточна група: #{current}"
            else
              "Головне меню.\nГрупу ще не вибрано."
            end

          bot.api.send_message(
            chat_id: chat_id,
            text: text_menu,
            reply_markup: main_menu_keyboard(!current.nil?)
          )

        when %r{\A/help\b}i
          current = user_group(chat_id)
          bot.api.send_message(
            chat_id: chat_id,
            text: build_help_text(current)
          )

        when %r{\A/mygroup\b}i
          current = user_group(chat_id)
          if current
            bot.api.send_message(chat_id: chat_id, text: "Твоя група: #{current}")
          else
            bot.api.send_message(chat_id: chat_id, text: "Групу ще не вибрано. Скористайся кнопкою «Група» або /group.")
          end

        when %r{\A/group\s+(.+)\z}i
          query   = Regexp.last_match(1)
          matches = find_groups_by_query(query)

          if matches.empty?
            bot.api.send_message(chat_id: chat_id, text: "За запитом «#{query}» груп не знайдено.")
          elsif matches.size == 1
            chosen = matches.first
            set_user_group(chat_id, chosen)
            USER_STATE.delete(chat_id.to_s)
            bot.api.send_message(
              chat_id: chat_id,
              text: "Вітаю, ви успішно знайшли свою групу!\nВаша група — #{chosen}.",
              reply_markup: group_menu_keyboard(true)
            )
          else
            kb = build_groups_keyboard(matches.take(30))
            bot.api.send_message(chat_id: chat_id, text: "Обери свою групу:", reply_markup: kb)
          end

        when %r{\A/setgroup\s+(.+)\z}i
          name_g = Regexp.last_match(1).strip
          if GROUPS.include?(name_g)
            set_user_group(chat_id, name_g)
            USER_STATE.delete(chat_id.to_s)
            bot.api.send_message(
              chat_id: chat_id,
              text: "Вітаю, ви успішно знайшли свою групу!\nВаша група — #{name_g}.",
              reply_markup: group_menu_keyboard(true)
            )
          else
            bot.api.send_message(chat_id: chat_id, text: "Групи «#{name_g}» немає у списку.")
          end

        when %r{\A/groups\b}i
          list = GROUPS.take(50).join("\n")
          bot.api.send_message(chat_id: chat_id, text: "Перші 50 груп:\n\n#{list}")

        when %r{\A/today\b}i
          current = user_group(chat_id)
          if current.nil?
            bot.api.send_message(
              chat_id: chat_id,
              text: "Спочатку обери свою групу кнопкою «Група» або /group.",
              reply_markup: main_menu_keyboard(false)
            )
          else
            refresh_group_schedule_on_demand(current)
            txt = schedule_for_day(SCHEDULE, current, Date.today)
            bot.api.send_message(
              chat_id: chat_id,
              text: txt,
              reply_markup: schedule_inline_keyboard,
              parse_mode: 'HTML'
            )
          end

        when %r{\A/tomorrow\b}i
          current = user_group(chat_id)
          if current.nil?
            bot.api.send_message(
              chat_id: chat_id,
              text: "Спочатку обери свою групу кнопкою «Група» або /group.",
              reply_markup: main_menu_keyboard(false)
            )
          else
            refresh_group_schedule_on_demand(current)
            txt = schedule_for_day(SCHEDULE, current, Date.today + 1)
            bot.api.send_message(
              chat_id: chat_id,
              text: txt,
              reply_markup: schedule_inline_keyboard,
              parse_mode: 'HTML'
            )
          end

        when %r{\A/day\b}i
          current = user_group(chat_id)
          if current.nil?
            bot.api.send_message(
              chat_id: chat_id,
              text: "Спочатку обери свою групу кнопкою «Група» або /group.",
              reply_markup: main_menu_keyboard(false)
            )
            next
          end

          parts = text.split(/\s+/, 2)
          if parts.size < 2
            bot.api.send_message(chat_id: chat_id, text: "Приклад: /day пн або /day friday")
            next
          end
          day_key = normalize_day_key(parts[1])
          if day_key.nil?
            bot.api.send_message(chat_id: chat_id, text: "Не розумію день «#{parts[1]}». Приклад: /day пн")
            next
          end

          refresh_group_schedule_on_demand(current)
          date = date_for_weekday_in_current_week(day_key, Date.today)
          txt  = schedule_for_day(SCHEDULE, current, date)
          bot.api.send_message(
            chat_id: chat_id,
            text: txt,
            reply_markup: schedule_inline_keyboard,
            parse_mode: 'HTML'
          )

        when %r{\A/week\b}i
          current = user_group(chat_id)
          if current.nil?
            bot.api.send_message(
              chat_id: chat_id,
              text: "Спочатку обери свою групу кнопкою «Група» або /group.",
              reply_markup: main_menu_keyboard(false)
            )
          else
            refresh_group_schedule_on_demand(current)
            txt = schedule_for_week(SCHEDULE, current, Date.today)
            bot.api.send_message(
              chat_id: chat_id,
              text: txt,
              reply_markup: schedule_inline_keyboard,
              parse_mode: 'HTML'
            )
          end

        when %r{\A/reload\b}i
          SCHEDULE.replace(load_json_hash(SCHEDULE_FILE))
          bot.api.send_message(chat_id: chat_id, text: "Розклад перезавантажено з файлу.")

        when %r{\A/update_group\s+(.+)\z}i
          name_u = Regexp.last_match(1).strip
          unless GROUPS.include?(name_u)
            bot.api.send_message(chat_id: chat_id, text: "Групи «#{name_u}» немає у списку GROUPS.")
            next
          end
          msg_u = update_schedule_from_site(name_u)
          bot.api.send_message(chat_id: chat_id, text: msg_u)

        when %r{\A/sync_group_ids\b}i
          updated = 0
          skipped = 0
          failed  = 0

          GROUPS.each do |name_s|
            if GROUP_SITE_IDS[name_s].is_a?(String) && !GROUP_SITE_IDS[name_s].to_s.strip.empty?
              skipped += 1
              next
            end

            id = fetch_group_id_for_name(name_s)
            if id
              GROUP_SITE_IDS[name_s] = id
              updated += 1
              save_group_site_ids(GROUP_SITE_IDS)
            else
              failed += 1
            end
            sleep 0.5
          end

          bot.api.send_message(
            chat_id: chat_id,
            text: "sync_group_ids завершено.\nОновлено: #{updated}\nПропущено (вже були): #{skipped}\nНе вдалося: #{failed}"
          )

        else
          # інші повідомлення поки ігноруємо
        end
      end
    rescue => e
      puts "[ERROR] #{e.class}: #{e.message}"
      # щоб бот не падав від одного кривого апдейта
    end
  end
end
