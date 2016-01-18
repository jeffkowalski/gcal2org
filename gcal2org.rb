#!/usr/bin/ruby

# Google Calendar API: https://developers.google.com/google-apps/calendar/quickstart/ruby
#                      https://developers.google.com/google-apps/calendar/v3/reference/
#                      https://console.developers.google.com

#require 'google/api_client'
require 'google/api_client/client_secrets'
require 'google/api_client/auth/installed_app'
require 'google/api_client/auth/storage'
require 'google/api_client/auth/storages/file_store'
require 'google/apis/calendar_v3'
require 'fileutils'
require 'logger'
require "net/http"
require "uri"
require 'base64'

LOGFILE = "/home/jeff/.gcal2org.log"

APPLICATION_NAME = 'gcal2org'
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
  startTime = ev['start']['dateTime']
  unless startTime
    date_only_s = true
    startTime = Time.parse(ev['start']['date'])
  end

  date_only_e = false
  endTime = ev['end']['dateTime']
  unless endTime
    date_only_e = true
    endTime = Time.parse(ev['end']['date'])
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
#redirect_output unless $DEBUG

$logger = Logger.new STDOUT
$logger.level = $DEBUG ? Logger::DEBUG : Logger::INFO
$logger.info 'starting'

# Initialize the API
Client = Google::Apis::CalendarV3::CalendarService.new
#Client = Google::APIClient.new(:application_name => APPLICATION_NAME)
Client.authorization = authorize
service = Client #Client.discovered_api('calendar', 'v3')

module Calendar
  class Time < ::Time
    def start_of_day
      Time.local(year, month, day)
    end
  end
end

page_token = nil
result = service.list_events(calendar_id: 'primary')
# ,
#                              time_min: Calendar::Time.new.start_of_day.iso8601,
#                              #single_events: "true",
#                              order_by: "startTime",
#                              max_results: 30,
#                              sort_order: 'a')
while true
  events = result.data.items
  events.each do |e|
    puts e.summary
  end
  break
  if !(page_token = result.data.next_page_token)
    break
  end
  result = Client.execute(:api_method => service.events.list,
                          :parameters => {:calendarId   => 'primary',
                                          :timeMin      => Calendar::Time.new.start_of_day.iso8601,
                                          :singleEvents => "true",
                                          :orderBy      => "startTime",
                                          :maxResults   => 30,
                                          :sortOrder    => 'a',
                                          :pageToken    => page_token})
end

exit
query = {:calendarId   => 'primary',
         :timeMin      => Calendar::Time.new.start_of_day.iso8601,
         :singleEvents => "true",
         :orderBy      => "startTime",
         :maxResults   => 30,
         :sortOrder    => 'a'}
events = Client.execute!(
  :api_method => service.events.list,
  :parameters => query)

puts events

exit
#results.data.messages.each { |message|
#events.each{|ev| puts ev.to_json }

#fname = "/home/jeff/Dropbox/workspace/org/gcal.org"
fname = "/tmp/gcal.org"
org = File.open(fname, "w")

def format_email person
  return [("\"#{person['displayName']}\"" if person['displayName']), "<#{person['email']}>"].join(' ')
end

events.first(100).each { |ev|
  org.puts '* ' + ev['summary']
  org.puts gcal_range_to_org_range(ev)
  org.puts ':PROPERTIES:'
  org.puts ':LOCATION: ' + ev['location'] if ev['location']
  org.puts ':ORGANIZER: ' + "#{format_email(ev['organizer'])}" if ev['organizer']
  ev['attendees'].each { |attendee|
    org.puts ':ATTENDEE: ' + "#{format_email(attendee)}"
  }
  org.puts ':END:'
  description = ev['description']
  if description
    description = description
                  .gsub(/^\*/, '-*')
                  .gsub(/_/, ' ')
                  .gsub(/\r$/, '')
                  .gsub(/ +$/, '')
                  .gsub(/^\n/, '')
    org.puts description
  end
}

org.close

$logger.info 'done'
