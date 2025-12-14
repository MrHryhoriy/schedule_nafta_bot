#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "nokogiri"
require "open-uri"

SCHEDULE_FILE = "schedule.json"

# URL сторінки з розкладом
KOLLEDZH_SCHEDULE_URL = "https://kep.if.ua/pages/education/schedule"

# Мапа назв днів українською -> ключі, які використовуються в schedule.json
DAY_MAP = {
  "Понеділок" => "mon",
  "Вівторок"  => "tue",
  "Середа"    => "wed",
  "Четвер"    => "thu",
  "П'ятниця"  => "fri",
  "П’ятниця"  => "fri", # з різними апострофами
  "Субота"    => "sat",
  "Неділя"    => "sun"
}.freeze

def load_schedule
  return {} unless File.exist?(SCHEDULE_FILE)

  JSON.parse(File.read(SCHEDULE_FILE))
rescue JSON::ParserError => e
  warn "Помилка парсингу #{SCHEDULE_FILE}: #{e.message}"
  {}
end

def save_schedule(schedule)
  File.write(SCHEDULE_FILE, JSON.pretty_generate(schedule))
end

def fetch_html
  URI.open(KOLLEDZH_SCHEDULE_URL, &:read)
end

def parse_group_schedule(html, group_name)
  doc = Nokogiri::HTML(html)

  # ⚠️ Тут ми шукаємо першу таблицю на сторінці.
  # Якщо їх кілька – можливо, треба буде уточнити селектор (наприклад, doc.css('table#schedule') або з класом).
  table = doc.css("table").first
  unless table
    raise "Не знайдена таблиця з розкладом на сторінці"
  end

  schedule = Hash.new { |h, k| h[k] = [] }

  # Пробігаємось по всіх рядках таблиці, пропускаючи заголовок
  rows = table.css("tr")
  rows[1..].each do |tr|
    tds = tr.css("td")
    next if tds.size < 6

    group   = tds[0].text.strip
    day_uk  = tds[1].text.strip
    para    = tds[2].text.strip
    subject = tds[3].text.strip
    room    = tds[4].text.strip
    weeks   = tds[5].text.strip

    # беремо тільки потрібну групу
    next unless group == group_name

    day_key = DAY_MAP[day_uk]
    next unless day_key # якщо день не розпізнали – пропускаємо

    # Формуємо один рядок так само, як у твоєму schedule.json
    # Можеш підкоригувати формат під себе
    line = "#{para}. #{subject} (ауд. #{room}, тижні: #{weeks})"
    schedule[day_key] << line
  end

  schedule
end

def update_group_schedule(group_name)
  puts "Завантажую сторінку розкладу..."
  html = fetch_html

  puts "Парсю розклад для групи #{group_name}..."
  group_schedule = parse_group_schedule(html, group_name)

  if group_schedule.empty?
    puts "⚠️ Для групи #{group_name} нічого не знайдено. Перевір, як вона записана на сайті."
    return
  end

  schedule = load_schedule
  schedule[group_name] = group_schedule

  save_schedule(schedule)
  puts "✅ Розклад для групи #{group_name} оновлено в #{SCHEDULE_FILE}"
end

if __FILE__ == $0
  group_name = ARGV.join(" ").strip
  if group_name.empty?
    warn "Використання: ruby update_schedule_from_site.rb \"НАЗВА_ГРУПИ\""
    warn "Приклад: ruby update_schedule_from_site.rb \"ІТ-21\""
    exit 1
  end

  update_group_schedule(group_name)
end
