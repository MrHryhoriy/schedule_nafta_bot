# sync_group_ids.rb
require 'json'
require 'net/http'
require 'uri'
require 'nokogiri'
require 'cgi'

BASE_URL       = "https://dekanat.nung.edu.ua/cgi-bin/timetable.cgi"
GROUPS_FILE    = "groups.json"
GROUP_IDS_FILE = "group_ids.json"

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

def percent_encode_cp1251(str)
  bytes = str.to_s.encode("Windows-1251", invalid: :replace, undef: :replace).bytes
  bytes.map { |b| "%%%02X" % b }.join
end

def post_cp1251(url, params)
  uri = URI(url)

  body = params.map do |k, v|
    key = URI.encode_www_form_component(k.to_s)
    val = percent_encode_cp1251(v.to_s)
    "#{key}=#{val}"
  end.join("&")

  http = Net::HTTP.new(uri.host, uri.port)
  http.use_ssl = (uri.scheme == "https")

  req = Net::HTTP::Post.new(uri.request_uri)
  req["Content-Type"] = "application/x-www-form-urlencoded"
  req.body = body

  http.request(req)
end

def extract_group_id_from_html(html)
  doc = Nokogiri::HTML(html)
  link = doc.at_css("h4 a[title*='Постійне посилання']")
  return nil unless link
  href = link["href"]
  return nil unless href

  begin
    uri = URI(href)
    query = CGI.parse(uri.query || "")
    if query["group"] && !query["group"].empty?
      return query["group"].first
    end
  rescue URI::InvalidURIError
  end

  href[/[?&]group=([^&]+)/, 1]
end

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

groups         = load_json_array(GROUPS_FILE)
group_site_ids = load_json_hash(GROUP_IDS_FILE)

updated = 0
skipped = 0
failed  = 0

groups.each do |name|
  if group_site_ids[name].is_a?(String) && !group_site_ids[name].to_s.strip.empty?
    skipped += 1
    next
  end

  id = fetch_group_id_for_name(name)
  if id
    group_site_ids[name] = id
    updated += 1
    save_json(GROUP_IDS_FILE, group_site_ids)
  else
    failed += 1
  end

  sleep 0.5
end

puts "Готово."
puts "Оновлено: #{updated}"
puts "Пропущено (вже мали id): #{skipped}"
puts "Не вдалося знайти id: #{failed}"
    