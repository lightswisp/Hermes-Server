require 'websocket-eventmachine-server'
require 'socket'
require 'openssl'
require 'colorize'
require 'timeout'
require 'ipaddress'
require 'securerandom'
require 'net/http'
require 'rb_tuntap'
require_relative 'public/webserver'

DEV_NAME = 'tun0'
PUBLIC_IP = Net::HTTP.get URI 'https://api.ipify.org'
LEASED_ADDRESSES = {} # All clients are gonna be here
NETWORK = IPAddress('192.168.0.0/24')
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
				data_split = data.split("\r\n").map{|line| line.downcase}
				if data_split.include?("connection: upgrade") || data_split.include?("upgrade: websocket")
					super
				else
					web_server = WebServer.new(data)
					send_data(web_server.response)
					close_connection_after_writing
				end

			end
  	end
  	
    class Server < Base
    	def set_status(status)
				@conn_status = status
    	end

    	def get_status
				@conn_status
    	end	
    	
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
  IO.popen(["iptables", "-t", "nat", "-A", "POSTROUTING", "-o", DEV_MAIN_INTERFACE, "-j", "MASQUERADE"]).close
	IO.popen(["iptables", "-A", "FORWARD", "-i", DEV_NAME, "-j", "ACCEPT"]).close
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

def valid_uuid?(uuid)
	return true if !uuid.empty? && uuid.match?(/[a-z0-9]+-[a-z0-9]+-[a-z0-9]+-[a-z0-9]+-[a-z0-9]+/) && uuid.size == 36
	return false
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
    ws.onopen do
      puts "Client connected"
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
      when /CONN_LEASE/
      	if ws.get_status != CONN_INIT
      		puts "Bad status on CONN_LEASE step!"
      		ws.send("Bad status on CONN_LEASE step!")
					ws.close
					next
      	end
      	
        uuid = request.split('/')[1]
        unless valid_uuid?(uuid)
        	puts "Invalid uuid format!"
        	ws.send("Invalid uuid format!")
					ws.close
					next
        end
        ws.set_id(uuid)
        address = lease_address(uuid)
        ws.send("#{CONN_LEASE}/#{address}-#{DEV_NETMASK}-#{PUBLIC_IP}")
        ws.set_status(CONN_LEASE)
      when CONN_CLOSE
        puts request
        if ws.get_id.nil?
					puts "Not yet fully connected!"
					ws.send("Not yet fully connected!")
					ws.close
					next
        end
        free_address(ws.get_id)
        p LEASED_ADDRESSES
        ws.set_status(CONN_CLOSE)
        ws.close
      when CONN_DONE

				if ws.get_status != CONN_LEASE
					puts "Bad Status on CONN_DONE step!"
					ws.send("Bad Status on CONN_DONE step!")
					ws.close
					next
				end
      	
        puts "CONN_DONE #{ws.get_id}"
        ws.set_status(CONN_DONE)
        THREADS[ws.get_id] = Thread.new do
          loop do
            buf = tun.to_io.sysread(MAX_BUFFER)
            ws.send([buf].pack('m0'))
          end
        end
      else
        begin
        	
        	if ws.get_status != CONN_DONE
						puts "Bad status on Data exchange step!"
						ws.close
						next
          end
         	request = request.unpack1('m0')
          tun.to_io.syswrite(request)
        # puts "Got #{request.size} bytes from client"
        rescue ArgumentError
          ws.send 'Error, malformed request!'
          ws.close
          next
        end
      end
    end

    ws.onclose do |_c|
      puts 'Client disconnected'
      id = ws.get_id
      unless id.nil?
        free_address(id)
        THREADS[id].exit if THREADS[id]
      end
    end
  end
end
