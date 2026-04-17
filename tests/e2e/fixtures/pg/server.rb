#!/usr/bin/env ruby
require 'webrick'
require 'pg'
require 'json'

host      = ENV.fetch('PCTL_HOST')
port      = Integer(ENV.fetch('WEB_PORT', '8080'))
mode      = ENV.fetch('DB_CONN_MODE', 'tcp')
pctl_id   = ENV.fetch('PCTL_ID')
socket_d  = "/run/user/#{Process.uid}/pctl-#{pctl_id}-pg"
db_name   = ENV.fetch('PG_DATABASE', 'app')
db_user   = ENV.fetch('PG_USER', 'postgres')

pg_port = Integer(ENV.fetch('PG_PORT', '5432'))

conn_args =
  case mode
  when 'tcp'    then { host: host,     port: pg_port, dbname: db_name, user: db_user }
  when 'socket' then { host: socket_d, port: pg_port, dbname: db_name, user: db_user }
  else raise "DB_CONN_MODE must be tcp|socket, got #{mode.inspect}"
  end

conn = PG.connect(**conn_args)

server = WEBrick::HTTPServer.new(BindAddress: host, Port: port, AccessLog: [])

server.mount_proc '/' do |_req, res|
  row = conn.exec('select id, name, added from things order by id asc limit 1').first
  res['Content-Type'] = 'application/json'
  res.body = JSON.generate(
    conn_mode: mode,
    host: host,
    port: port,
    row: row
  )
end

trap('INT')  { server.shutdown }
trap('TERM') { server.shutdown }
server.start
