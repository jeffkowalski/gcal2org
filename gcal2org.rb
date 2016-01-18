#!/usr/bin/env ruby
# coding: utf-8

# A script to fetch calendar events from Google via Google Calendar API
#
# reference:
# https://developers.google.com/google-apps/calendar/setup
# https://developers.google.com/google-apps/calendar/instantiate
# https://developers.google.com/google-apps/calendar/v3/reference/events/list#examples
# https://developers.google.com/google-apps/calendar/v3/reference/

require 'google/api_client' # see http://code.google.com/p/google-api-ruby-client/
require 'yaml'

module OAuth
  class Google
    @@config_file=ENV['HOME'] + '/.google-api.yaml'
    class << self
      def load
        if File.exist?(@@config_file)
          return YAML.load_file(@@config_file)
        else
          warn "#@@config_file not found"
          self.abort_config_needed
        end
      end

      def abort_config_needed
        abort <<INTRO_TO_AUTH
    This utility requires valid oauth credentials and token for your project in the
    config file '#@@config_file'.

    You can create it by jumping through some oauth hoops by setting up a project and then
    using the google-api command, provided by the google-api-client gem:

    - Go to Google API Console at https://code.google.com/apis/console/ and set up a project
      that you will use to access this data.
     - In the "API Access" section, in the list of "Redirect URIs" include
       'http://localhost:12736/'.
     - Get your project's CLIENT_ID and CLIENT_SECRET to use below.

    - Users (including you) will need to grant permissions to access their calendars.
     - Generate the config file '#@@config_file' by calling the following, which will launch
       the browser and write the config file:
    (LD_LIBRARY_PATH=
     CLIENT_ID=[YOUR-CLIENT_ID]
     CLIENT_SECRET=[YOUR-CLIENT-SECRET]
     google-api oauth-2-login --scope=https://www.googleapis.com/auth/calendar --client-id="$CLIENT_ID" --client-secret="$CLIENT_SECRET" )
INTRO_TO_AUTH
      end
    end
  end
end

module Calendar
  class Time < ::Time
    def start_of_day
      Time.local(year, month, day)
    end
  end
end

module Calendar
  class GoogleAPIClient < ::Google::APIClient
    attr_reader :client
    def initialize(oauth)
      super
      authorization.client_id     = oauth["client_id"]
      authorization.client_secret = oauth["client_secret"]
      authorization.scope         = oauth["scope"]
      authorization.refresh_token = oauth["refresh_token"]
      authorization.access_token  = oauth["access_token"]

      # NB: seems authorization.expired? does not work b/c times are not stored
      # in the yaml -- so we just call authorization.fetch_access_token! on error
      # see update_token! in http://code.google.com/p/google-api-ruby-client/wiki/OAuth2
      #if authorization.refresh_token && authorization.expired?
      #  authorization.fetch_access_token!
      #end
    end

    def fetch_data_with_retry(api_method, params)
      data = execute_aux(api_method, params).data
      if data_error(data) # try refereshing the access token and updating the data
        authorization.fetch_access_token!
        data = execute_aux(api_method, params).data
      end
      if err = data_error(data) # raise exception if still an error
        raise RuntimeError, err.to_json
      end
      return data
    end

    private
    def execute_aux(api_method, params)
      execute(:api_method => api_method, :parameters => params)
    end

    def data_error(data)
      data.to_hash["error"]
    end
  end
end

module Calendar
  class GoogleCalendarClient < GoogleAPIClient
    def events(query)
      Enumerator.new {|y| events_aux(query){|event| y << event}}
    end

    private
    def events_aux(cal_query, &block) # requires a block
      data = list_events(cal_query)
      data.items.each(&block)
      if page_token = data.next_page_token
        events_aux(cal_query.merge(:pageToken => page_token), &block)
      end
    end

    # Params are as described in:
    # https://developers.google.com/google-apps/calendar/v3/reference/events/list
    def list_events(params)
      fetch_data_with_retry(calendar_service.events.list, params)
    end

    def calendar_service
      discovered_api('calendar', 'v3')
    end
  end
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

cal = Calendar::GoogleCalendarClient.new(OAuth::Google.load)
query = {:calendarId   => 'primary',
         :timeMin      => Calendar::Time.new.start_of_day.iso8601,
         :singleEvents => "true",
         :orderBy      => "startTime",
         :maxResults   => 30,
         :sortOrder    => 'a'}
events = cal.events(query)
#events.each{|ev| puts ev.to_json }

fname = "/home/jeff/Dropbox/workspace/org/gcal.org"
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
