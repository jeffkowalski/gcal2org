#!/usr/bin/env ruby

# Google Calendar API: https://developers.google.com/google-apps/calendar/quickstart/ruby
#                      https://developers.google.com/google-apps/calendar/v3/reference/
#                      https://console.developers.google.com
# Google API Ruby Client:  https://github.com/google/google-api-ruby-client

require 'googleauth'
require 'googleauth/stores/file_token_store'
require 'google/apis/calendar_v3'
require 'fileutils'
require 'logger'
require 'thor'
require 'resolv-replace'

ORGPATH = File.join(Dir.home, 'Dropbox/workspace/org')
LOGFILE = File.join(Dir.home, '.log', 'gcal2org.log')

OOB_URI = 'urn:ietf:wg:oauth:2.0:oob'
APPLICATION_NAME = 'gcal2org'
CLIENT_SECRETS_PATH = 'client_secret.json'
CREDENTIALS_PATH = File.join(Dir.home, '.credentials', "gcal2org.yaml")
SCOPE = 'https://www.googleapis.com/auth/calendar.readonly'

##
# Ensure valid credentials, either by restoring from the saved credentials
# files or intitiating an OAuth2 authorization. If authorization is required,
# the user's default browser will be launched to approve the request.
#
# @return [Google::Auth::UserRefreshCredentials] OAuth2 credentials
def authorize interactive
  FileUtils.mkdir_p(File.dirname(CREDENTIALS_PATH))
  client_id = Google::Auth::ClientId.from_file(CLIENT_SECRETS_PATH)
  token_store = Google::Auth::Stores::FileTokenStore.new(file: CREDENTIALS_PATH)
  authorizer = Google::Auth::UserAuthorizer.new(client_id, SCOPE, token_store)
  user_id = 'default'
  credentials = authorizer.get_credentials(user_id)
  if credentials.nil? and interactive
    url = authorizer.get_authorization_url(base_url: OOB_URI)
    code = ask("Open the following URL in the browser and enter the resulting code after authorization\n" + url)
    credentials = authorizer.get_and_store_credentials_from_code(
      user_id: user_id, code: code, base_url: OOB_URI)
  end
  credentials
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


module Calendar
  class Time < ::Time
    def start_of_day
      Time.local(year, month, day)
    end
  end
end


class GCal2Org < Thor
  no_commands {
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

    def setup_logger
      redirect_output if options[:log]

      $logger = Logger.new STDOUT
      $logger.level = options[:verbose] ? Logger::DEBUG : Logger::INFO
      $logger.info 'starting'
    end
  }

  class_option :log,     :type => :boolean, :default => true, :desc => "log output to ~/.gcal2org.log"
  class_option :verbose, :type => :boolean, :aliases => "-v", :desc => "increase verbosity"

  desc "auth", "Authorize the application with google services"
  def auth
    setup_logger
    #
    # initialize the API
    #
    begin
      service = Google::Apis::CalendarV3::CalendarService.new
      service.client_options.application_name = APPLICATION_NAME
      service.authorization = authorize !options[:log]
      service
    rescue Exception => e
      $logger.error e.message
      $logger.error e.backtrace.inspect
    end
  end

  desc "scan", "Scan calendar"
  def scan
    calendar = auth
    [{:file => 'jeff.org',     :calendar => 'primary'},
     {:file => 'michelle.org', :calendar => 'bowen.kowalski@gmail.com'}].each do |source|
      $logger.info "Fetching calendar #{source[:calendar]} into #{source[:file]}"
      File.open(File.join(ORGPATH, "#{source[:file]}"), "w") do |org|

        limit = 30
        page_token = nil
        begin
          result = calendar.list_events(source[:calendar],
                                        max_results: [100, limit].min,
                                        single_events: true,
                                        order_by: 'startTime',
                                        time_min: Calendar::Time.new.start_of_day.iso8601,
                                        page_token: page_token,
                                        fields: 'items(id,summary,location,organizer,attendees,description,start,end),next_page_token')

          result.items.each do |event|
            org.puts '* ' + (event.summary.nil? ? '(No title)' : event.summary)
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
    rescue Exception => e
      $logger.error e.message
      $logger.error e.backtrace.inspect
    end

    $logger.info 'done'
  end
end

GCal2Org.start
