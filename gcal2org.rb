#!/usr/bin/ruby2.0

# Google Calendar API: https://developers.google.com/google-apps/calendar/quickstart/ruby
#                      https://developers.google.com/google-apps/calendar/v3/reference/
#                      https://console.developers.google.com
# Google API Ruby Client:  https://github.com/google/google-api-ruby-client

require 'google/api_client'
require 'google/api_client/client_secrets'
require 'google/api_client/auth/installed_app'
require 'google/api_client/auth/storage'
require 'google/api_client/auth/storages/file_store'
require 'google/apis/calendar_v3'
require 'logger'

ORGFILE = File.join(Dir.home, 'Dropbox/workspace/org', 'gcal.org')
LOGFILE = File.join(Dir.home, '.gcal2org.log')

CLIENT_SECRETS_PATH = 'client_secret.json'
CREDENTIALS_PATH = File.join(Dir.home, '.credentials', "gcal2org.json")
SCOPE = 'https://www.googleapis.com/auth/calendar.readonly'

##
# Ensure valid credentials, either by restoring from the saved credentials
# files or intitiating an OAuth2 authorization request via InstalledAppFlow.
# If authorization is required, the user's default browser will be launched
# to approve the request.
#
# @return [Signet::OAuth2::Client] OAuth2 credentials
def authorize
  FileUtils.mkdir_p(File.dirname(CREDENTIALS_PATH))

  file_store = Google::APIClient::FileStore.new(CREDENTIALS_PATH)
  storage = Google::APIClient::Storage.new(file_store)
  auth = storage.authorize

  if auth.nil? || (auth.expired? && auth.refresh_token.nil?)
    app_info = Google::APIClient::ClientSecrets.load(CLIENT_SECRETS_PATH)
    flow = Google::APIClient::InstalledAppFlow.new({
                                                     :port => 4567,
                                                     :client_id => app_info.client_id,
                                                     :client_secret => app_info.client_secret,
                                                     :scope => SCOPE})
    auth = flow.authorize(storage)
    $logger.info "credentials saved to #{CREDENTIALS_PATH}" unless auth.nil?
  end
  auth
end


def gcal_range_to_org_range(ev)
  date_only_s = false
  startTime = ev.start.date_time
  unless startTime
    date_only_s = true
    startTime = Time.parse(ev.start.date)
  end

  date_only_e = false
  endTime = ev.end.date_time
  unless endTime
    date_only_e = true
    endTime = Time.parse(ev.end.date)
  end

  if date_only_s && date_only_e
    if endTime.eql?(startTime + 86400)
      return startTime.strftime("<%Y-%m-%d %a>")
    else
      return startTime.strftime("<%Y-%m-%d %a>") + '--' + (endTime-84000).strftime("<%Y-%m-%d %a>")
    end
  else
    return startTime.strftime("<%Y-%m-%d %a %H:%M>") + '--' + endTime.strftime("<%Y-%m-%d %a %H:%M>")
  end
end


def format_email person
  return [("\"#{person.display_name}\" " if person.display_name), "<#{person.email}>"].join('')
end


def redirect_output
  unless LOGFILE == 'STDOUT'
    logfile = File.expand_path(LOGFILE)
    FileUtils.mkdir_p(File.dirname(logfile), :mode => 0755)
    FileUtils.touch logfile
    File.chmod 0644, logfile
    $stdout.reopen logfile, 'a'
  end
  $stderr.reopen $stdout
  $stdout.sync = $stderr.sync = true
end


# setup logger
redirect_output unless $DEBUG

$logger = Logger.new STDOUT
$logger.level = $DEBUG ? Logger::DEBUG : Logger::INFO
$logger.info 'starting'

# Initialize the API
Calendar = Google::Apis::CalendarV3
Client = Calendar::CalendarService.new
Client.authorization = authorize
calendar = Client

module Calendar
  class Time < ::Time
    def start_of_day
      Time.local(year, month, day)
    end
  end
end


File.open(ORGFILE, "w") do |org|

  limit = 30
  page_token = nil
  begin
    result = calendar.list_events('primary',
                                  max_results: [100, limit].min,
                                  single_events: true,
                                  order_by: 'startTime',
                                  time_min: Calendar::Time.new.start_of_day.iso8601,
                                  page_token: page_token,
                                  fields: 'items(id,summary,location,organizer,attendees,description,start,end),next_page_token')

    result.items.each do |event|
      org.puts '* ' + event.summary
      org.puts gcal_range_to_org_range(event)
      org.puts ':PROPERTIES:'
      org.puts ':LOCATION: ' + event.location if event.location
      org.puts ':ORGANIZER: ' + "#{format_email(event.organizer)}" if event.organizer
      event.attendees.each do |attendee|
        org.puts ':ATTENDEE: ' + "#{format_email(attendee)}"
      end if event.attendees
      org.puts ':END:'
      description = event.description
      if description
        description = description
                      .gsub(/^\*/, '-*')
                      .gsub(/_/,   ' ')
                      .gsub(/\r$/, '')
                      .gsub(/ +$/, '')
                      .gsub(/^\n/, '')
        org.puts description
      end
    end

    limit -= result.items.length
    if result.next_page_token
      page_token = result.next_page_token
    else
      page_token = nil
    end
  end while !page_token.nil? && limit > 0

end

$logger.info 'done'
