require 'websocket-eventmachine-server'
require 'socket'
require 'openssl'
require 'colorize'
require 'timeout'
require 'ipaddress'
require 'securerandom'
require 'net/http'
require 'rb_tuntap'

DEV_NAME = 'tun0'
PUBLIC_IP = Net::HTTP.get URI 'https://api.ipify.org'
LEASED_ADDRESSES = {} # All clients are gonna be here
NETWORK = IPAddress('192.168.0.0/24')
DEV_MAIN_INTERFACE = 'eth0'
DEV_NETMASK = NETWORK.netmask
DEV_ADDR = NETWORK.first.to_s

CONN_INIT	= 'CONN_INIT'
CONN_LEASE = 'CONN_LEASE'
CONN_DONE = 'CONN_DONE'
CONN_CLOSE = 'CONN_CLOSE'
MAX_BUFFER = 1024 * 4

THREADS = {}

module WebSocket
  module EventMachine
    class Server < Base
      def set_id(id)
        @id = id
      end

      def get_id
        @id
      end
    end
  end
end

def setup_forwarding
  `echo 1 > /proc/sys/net/ipv4/ip_forward`
  `iptables -t nat -A POSTROUTING -o #{DEV_MAIN_INTERFACE} -j MASQUERADE`
  `iptables -A FORWARD -i #{DEV_NAME} -j ACCEPT`
end

def close_tun(tun)
  tun.down
  tun.close
  puts 'tun closed'
  exit
end

def setup_tun
  tun = RbTunTap::TunDevice.new(DEV_NAME) # DEV_NAME = 'tun0'
  tun.open(true)

  trap 'SIGINT' do
    close_tun(tun)
  end
  tun.addr = DEV_ADDR
  tun.netmask = DEV_NETMASK
  tun.up
  tun
end

def lease_address(uuid)
  free_addresses = NETWORK.to_a[2...-1].reject { |x| LEASED_ADDRESSES.include?(x.to_s) }
  random_address = free_addresses.sample.to_s
  LEASED_ADDRESSES.merge!(random_address => uuid)
  random_address
end

def free_address(uuid)
  LEASED_ADDRESSES.delete_if { |_k, v| v == uuid }
end

tun = setup_tun # setup the tun interface
setup_forwarding # setup the NAT and forwarding

EM.run do
  WebSocket::EventMachine::Server.start(
    host: '0.0.0.0',
    port: 443,
    secure: true,
    tls_options: {
      private_key_file: 'private.key',
      cert_chain_file: 'certificate.crt'
    }
  ) do |ws|
    ws.onopen do |c|
      ip = c.headers['x-forwarded-for']
      puts "Client connected #{ip.nil? ? 'nil' : ip}"
    end

    ws.onmessage do |request, _type|
      # puts "Received message: #{request}"

      if request.empty?
        ws.send 'Error, request is empty!'
        next
      end

      case request
      when CONN_INIT
        ws.send(request)
      when /CONN_LEASE/
        uuid = request.split('/')[1]
        ws.set_id(uuid)
        address = lease_address(uuid)
        p LEASED_ADDRESSES
        ws.send("#{CONN_LEASE}/#{address}-#{DEV_NETMASK}-#{PUBLIC_IP}")
      when /CONN_CLOSE/
        puts request
        uuid = request.split('/')[1]
        free_address(uuid)
        p LEASED_ADDRESSES
      when CONN_DONE
        puts "CONN_DONE #{ws.get_id}"
        THREADS[ws.get_id] = Thread.new do
          loop do
            buf = tun.to_io.sysread(MAX_BUFFER)
            ws.send([buf].pack('m0'))
            # puts "Sent #{buf.size} bytes"
          end
        end
      else
        begin
          request = request.unpack1('m0')
          tun.to_io.syswrite(request)
        # puts "Got #{request.size} bytes from client"
        rescue ArgumentError
          p 'error'
          ws.send 'Error, malformed request!'
          next
        end
      end
    end

    ws.onclose do |_c|
      puts 'Client disconnected'
      if id = ws.get_id
        free_address(id)
        THREADS[id].exit
      end
    end
  end
end
