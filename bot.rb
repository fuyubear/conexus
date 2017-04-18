if ARGV.length != 2
  puts 'Usage: ruby bot.rb <token> <client_id>'
  exit
end
require 'rubygems'

require 'bundler/setup'
Bundler.setup(:default)

require 'fileutils'
require 'yaml'
require 'discordrb'

# This hash will store voice channel_ids mapped to text_channel ids
# {
#   "267526886454722560": "295714345344565249",
#   etc.
# }
FileUtils.touch('associations.yaml')
ASSOCIATIONS = YAML.load_file('associations.yaml')
ASSOCIATIONS ||= Hash.new

OLD_VOICE_STATES = Hash.new

# These are the perms given to people for a associated voice-channel
TEXT_PERMS = Discordrb::Permissions.new
TEXT_PERMS.can_read_message_history = true
TEXT_PERMS.can_read_messages = true
TEXT_PERMS.can_send_messages = true

bot = Discordrb::Bot.new token: ARGV.first, client_id: ARGV[1] 

bot.ready { |event| bot.servers.each { |_, server| setup_server(server) } }

bot.server_create { |event| event.server.member(event.bot.profile.id).nick = "🔗"; setup_server(event.server) }

def setup_server(server)
  
  puts "Setting up [#{server.name}]"
  puts 'Trimming associations'
  trim_associations(server)
  puts 'Cleaning up after restart'
  server.text_channels.select { |tc| tc.name == 'voice-channel' }.each do |tc|
    unless ASSOCIATIONS.values.include?(tc.id)
      tc.delete
      next
    end
    vc = server.voice_channels.find { |vc| vc.id == ASSOCIATIONS.key(tc) }
    tc.users.select { |u| !vc.users.include?(u) }.each do |u|
      tc.define_overwrite(u, 0, 0)
    end
  end
  puts 'Associating'
  server.voice_channels.each { |vc| associate(vc) }
  OLD_VOICE_STATES[server.id] = server.voice_states.clone
  puts "Done\n"
end

def simplify_voice_states(voice_states)
  clone = voice_states.clone
  clone.each { |user_id, state| clone[user_id] = state.voice_channel }
  
  return clone
end

def trim_associations(server)
  ASSOCIATIONS.each do |vc_id, tc_id|
    ASSOCIATIONS.delete(vc_id) if tc_id.nil? || server.voice_channels.find { |vc| vc.id == vc_id }.nil?
  end
  save
end

def associate(voice_channel)
  server = voice_channel.server
  return if voice_channel == server.afk_channel # No need for AFK channel to have associated text-channel

  puts "Associating '#{voice_channel.name} / #{server.name}'"
  text_channel = server.text_channels.find { |tc| tc.id == ASSOCIATIONS[voice_channel.id] }

  if ASSOCIATIONS[voice_channel.id].nil? || text_channel.nil?
    text_channel = server.create_channel('voice-channel', 0) # Creates a matching text-channel called 'voice-channel'
    text_channel.topic = "Private chat for all those in the voice-channel [**#{voice_channel.name}**]."
    
    voice_channel.users.each do |u|
      text_channel.define_overwrite(u, TEXT_PERMS, 0)
    end

    text_channel.define_overwrite(voice_channel.server.roles.find { |r| r.id == voice_channel.server.id }, 0, TEXT_PERMS) # Set default perms as invisible
    ASSOCIATIONS[voice_channel.id] = text_channel.id # Associate the two 
    save
  end

  text_channel
end

def handle_user_change(action, voice_channel, user)
  puts "Handling user #{action} for '#{voice_channel.name} / #{voice_channel.server.name}' for #{user.distinct}"
  text_channel = associate(voice_channel) # This will create it if it doesn't exist. Pretty cool!

  # For whatever reason, maybe is AFK channel
  return if text_channel.nil?

  if action == :join
    text_channel.send_message("**#{user.display_name}** joined the voice-channel.")
    text_channel.define_overwrite(user, TEXT_PERMS, 0)
  else
    text_channel.send_message("**#{user.display_name}** left the voice-channel.")
    text_channel.define_overwrite(user, 0, 0)
  end
end

# VOICE-CHANNEL CREATED
bot.channel_create(type: 2) do |event|
  associate(event.channel)
end

# VOICE-CHANNEL DELETED
bot.channel_delete(type: 2) do |event|
  event.server.text_channels.select { |tc| tc.id == ASSOCIATIONS[event.id] }.map(&:delete)
  trim_associations(event.server)
end

bot.voice_state_update do |event|
  old = simplify_voice_states(OLD_VOICE_STATES[event.server.id])
  current = simplify_voice_states(event.server.voice_states)
  member = event.user.on(event.server)

  if event.old_channel != event.channel #current[member.id] != old[member.id]
    # Something has happened
    handle_user_change(:leave, event.old_channel, member) unless event.old_channel.nil?
    handle_user_change(:join, event.channel, member) unless event.channel.nil?

    OLD_VOICE_STATES[event.server.id] = event.server.voice_states.clone
  end
end

def save
  File.open('associations.yaml', 'w') {|f| f.write ASSOCIATIONS.to_yaml }
end

#bot.invisible
puts "Oauth url: #{bot.invite_url}+&permissions=8"

bot.run :async
bot.dnd
bot.profile.name = 'conexus'
bot.sync