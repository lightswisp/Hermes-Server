#!/usr/bin/ruby
require 'websocket-eventmachine-server'
require 'socket'
require 'openssl'
require 'colorize'
require 'timeout'
require 'ipaddress'
require 'securerandom'
require 'net/http'
require_relative 'tun'
require_relative 'webserver/webserver'

include RubyTun

CERT_PATH = '/etc/hermes/certificate.crt'
KEY_PATH  = '/etc/hermes/private.key'
Dir.mkdir('/etc/hermes') unless Dir.exist?('/etc/hermes')

unless File.exist?('/etc/hermes/certificate.crt') && File.exist?('/etc/hermes/private.key')
  puts 'No certificate.crt and private.key files found!'.red.bold
  exit
end

DEV_NAME = 'tun0'
PUBLIC_IP = Net::HTTP.get URI 'https://api.ipify.org'
LEASED_ADDRESSES = {} # All clients are gonna be here
NETWORK = IPAddress('172.16.8.0/24')
DNS_ADDR = '8.8.8.8' # google dns for clients
DEV_MAIN_INTERFACE = 'eth0'
DEV_NETMASK = NETWORK.netmask
DEV_ADDR = NETWORK.first.to_s

CONN_OPEN = 'CONN_OPEN'
CONN_INIT	= 'CONN_INIT'
CONN_LEASE = 'CONN_LEASE'
CONN_DONE = 'CONN_DONE'
CONN_CLOSE = 'CONN_CLOSE'
MAX_BUFFER = 1024 * 4

THREADS = {}

module WebSocket
  module EventMachine
    class Base < Connection
      def receive_data(data)
        # port, ip = Socket.unpack_sockaddr_in(get_peername)
        # puts "got #{data.inspect} from #{ip}:#{port}"
        # this is not very efficient method to differ the data
        # need to fix it later
        data_split = data.split("\r\n").map { |line| line.downcase }
        if data_split[0].match?(%r{[a-z]+\s/.*\shttp/1\.1})
          if data_split.include?('connection: upgrade') || data_split.include?('upgrade: websocket')
            case @state
            when :connecting then handle_connecting(data)
            when :open then handle_open(data)
            when :closing then handle_closing(data)
            end
          else
            web_server = WebServer.new(data)
            send_data(web_server.response)
            close_connection_after_writing
          end
        else
          case @state
          when :connecting then handle_connecting(data)
          when :open then handle_open(data)
          when :closing then handle_closing(data)
          end
        end
      end
    end

    class Server < Base

	  def set_peer(peername)
		@peername = peername
	  end

	  def get_peer
		return @peername
	  end
      
      def set_status(status)
        @conn_status = status
      end

      def get_status
        @conn_status
      end

    end
  end
end

def setup_forwarding
  File.write('/proc/sys/net/ipv4/ip_forward', '1')
  IO.popen(['iptables', '-t', 'nat', '-A', 'POSTROUTING', '-o', DEV_MAIN_INTERFACE, '-j', 'MASQUERADE']).close
  IO.popen(['iptables', '-A', 'FORWARD', '-i', DEV_NAME, '-j', 'ACCEPT']).close
  IO.popen(['iptables', '-A', 'FORWARD', '-o', DEV_NAME, '-j', 'ACCEPT']).close
  puts 'Forwarding is done!'
end

def close_tun(tun)
  tun.down
  tun.close
  puts 'tun closed'
  exit
end

def setup_tun
  tun = RubyTun::TunDevice.new(DEV_NAME)
  tun.open
  tun.init
  tun.set_addr(DEV_ADDR)
  tun.set_netmask(DEV_NETMASK)
  tun.up
  tun.tun
end

def lease_address(ws)
  free_addresses = NETWORK.to_a[2...-1].reject { |x| LEASED_ADDRESSES.include?(x.to_s) }
  random_address = free_addresses.sample.to_s
  LEASED_ADDRESSES.merge!(random_address => ws)
  random_address
end

def free_address(peername)
  LEASED_ADDRESSES.delete_if { |k, v| k == peername }
end


tun = setup_tun # setup the tun interface
setup_forwarding # setup the NAT and forwarding

EM.run do
  WebSocket::EventMachine::Server.start(
    host: '0.0.0.0',
    port: 443,
    secure: true,
    tls_options: {
      private_key_file: KEY_PATH,
      cert_chain_file: CERT_PATH,
    }
  ) do |ws|
    ws.onopen do
      puts 'Client connected'
      
      ws.set_status(CONN_OPEN)
    end

    ws.onmessage do |request, _type|
      # puts "Received message: #{request}"
      if request.empty?
        ws.send 'Error, request is empty!'
        ws.close
        next
      end

      case request
      when CONN_INIT
        ws.send(request)
        ws.set_status(CONN_INIT)
      when CONN_LEASE
        if ws.get_status != CONN_INIT
          puts 'Bad status on CONN_LEASE step!'
          ws.send('Bad status on CONN_LEASE step!')
          ws.close
          next
        end
		# need to check if address pool is empty
        address = lease_address(ws)
        ws.set_peer(address)
        ws.send("#{CONN_LEASE}/#{address}-#{DEV_NETMASK}-#{PUBLIC_IP}-#{DNS_ADDR}")
        ws.set_status(CONN_LEASE)
      when CONN_CLOSE
      	peer = ws.get_peer
      	unless peer.nil?
	        free_address(peer) if [CONN_LEASE, CONN_DONE].include?(ws.get_status)
	        if THREADS[peer]
				THREADS[peer].exit 
				THREADS.delete(peer)
	        end
        end
        p "Leased addresses: #{LEASED_ADDRESSES}"
        
        ws.set_status(CONN_CLOSE)
        ws.close
      when CONN_DONE

        if ws.get_status != CONN_LEASE
          puts 'Bad Status on CONN_DONE step!'
          ws.send('Bad Status on CONN_DONE step!')
          ws.close
          next
        end

        puts "CONN_DONE #{ws.get_peer}"
        ws.set_status(CONN_DONE)
      
        THREADS[ws.get_peer] = Thread.new(ws) do |ws|
          loop do
            buf = tun.to_io.sysread(MAX_BUFFER)
            buf_bytes = buf.unpack("C*")
            ip_destination = buf_bytes[16...20].join(".")
            
            if LEASED_ADDRESSES[ip_destination]
            	LEASED_ADDRESSES[ip_destination].send([buf].pack('m0'))
            else
            	next
            end
           
          end
        end
      else
        begin
          if ws.get_status != CONN_DONE
            puts 'Bad status on Data exchange step!'
            ws.close
            next
          end
          request = request.unpack1('m0')
          begin
          	request_bytes = request.unpack("C*")
          	ip_version = ((request_bytes[0] & 0xF0) >> 4)
          	next unless ip_version == 4 # ipv4 packet
          	ip_destination = request_bytes[16...20].join(".")
          	next if ip_destination == "255.255.255.255" # if broadcast
            tun.to_io.syswrite(request)
          rescue StandardError
            puts 'Ivalid packet'
          end
        rescue ArgumentError
          ws.send 'Error, malformed request!'
          ws.close
          next
        end
      end
    end

    ws.onclose do |_c|
      puts 'Client disconnected'
      peer = ws.get_peer
      
      unless peer.nil?
        free_address(peer) if [CONN_LEASE, CONN_DONE].include?(ws.get_status)
        if THREADS[peer]
			THREADS[peer].exit 
			THREADS.delete(peer)
        end
      end
    end
  end
end
