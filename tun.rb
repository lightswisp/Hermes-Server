require 'ipaddr'
require 'socket'
require 'fiddle'
require 'fiddle/import'

# struct ifmap {
# unsigned long   mem_start;
# unsigned long   mem_end;
# unsigned short  base_addr;
# unsigned char   irq;
# unsigned char   dma;
# unsigned char   port;
# };

# struct sockaddr {
# unsigned short  sa_family;
# char    sa_data[14];
# };

# struct sockaddr_in {
# short            sin_family;   // e.g. AF_INET, AF_INET6
# unsigned short   sin_port;     // e.g. htons(3490)
# unsigned long    s_addr ;
# char             sin_zero[8];
# };

# struct ifreq {
# char ifr_name[IFNAMSIZ]; /* Interface name */
# union {
# struct sockaddr ifr_addr;
# struct sockaddr ifr_dstaddr;
# struct sockaddr ifr_broadaddr;
# struct sockaddr ifr_netmask;
# struct sockaddr ifr_hwaddr;
# short           ifr_flags;
# int             ifr_ifindex;
# int             ifr_metric;
# int             ifr_mtu;
# struct ifmap    ifr_map;
# char            ifr_slave[IFNAMSIZ];
# char            ifr_newname[IFNAMSIZ];
# char           *ifr_data;
# };
# };

module RubyTun
  extend Fiddle::Importer

  IFNAMSIZ = 16

  AF_NETLINK = 16
  NETLINK_ROUTE = 0

  TUNSETIFF = 0x400454CA
  TUNSETOWNER = 0x400454CC
  SIOCSIFFLAGS = 0x8914
  SIOCSIFADDR = 0x8916
  SIOCSIFNETMASK = 0x891c
  SIOCADDRT = 0x890B

  Tun = 0x0001
  Tap = 0x0002
  NoPi = 0x1000
  OneQueue = 0x2000
  VnetHdr = 0x4000
  TunExcl = 0x8000
  MultiQueue = 0x0100
  AttachQueue = 0x0200
  DetachQueue = 0x0400
  Persist = 0x0800
  NoFilter = 0x1000
  Up = 0x0001
  Broadcast = 0x0002
  Debug = 0x0004
  Loopback = 0x0008
  PointToPoint = 0x0010
  NoTrailers = 0x0020
  Running = 0x0040
  NoArp = 0x0080
  Promisc = 0x0100
  AllMulti = 0x0200
  Master = 0x0400
  Slave = 0x0800
  Multicast = 0x1000
  PortSel = 0x2000
  AutoMedia = 0x4000
  Dynamic = 0x8000

  Ifmap = struct [
    'unsigned long mem_start',
    'unsigned long mem_end',
    'unsigned short base_addr',
    'unsigned char irq',
    'unsigned char dma',
    'unsigned char port'
  ]

  Sockaddr = struct [
    'unsigned short sa_family',
    'char sa_data[14]'
  ]

  Ifreq_union = union [
    { ifr_addr: Sockaddr },
    { ifr_dstaddr: Sockaddr },
    { ifr_broadaddr: Sockaddr },
    { ifr_netmask: Sockaddr },
    { ifr_hwaddr: Sockaddr },
    'short ifr_flags',
    'int ifr_ifindex',
    'int ifr_mtu',
    { ifr_map: Ifmap },
    'char ifr_slave[16]',
    'char ifr_newname[16]',
    'char* ifr_data'
  ]

  Ifreq = struct [
    'char ifr_name[16]',
    { iu: Ifreq_union }
  ]

  class TunDevice
    attr_accessor :tun

    def initialize(name = 'tun0')
      @name = name
      @fd = 0
      @tun = nil
    end

    def open
      fd = 0
      if (fd = IO.sysopen('/dev/net/tun', 'r+b')) == 0
        puts 'Failed to open tun device!'
        exit(1)
      end
      @fd = fd
    end

    def init
      ifr = RubyTun::Ifreq.malloc
      if @fd == 0
        puts 'Tun device is not open!'
        exit(1)
      end
      ifr.iu.ifr_flags = RubyTun::Tun | RubyTun::NoPi
      ifr.ifr_name = [@name].pack('a16')
      p ifr.ifr_name[0]
      ifr_size = ifr.to_ptr.size
      @tun = IO.new(@fd, 'r+b')
      flags = ifr[0, ifr_size]
      begin
        @tun.ioctl(RubyTun::TUNSETIFF, flags)
        @tun.ioctl(TUNSETOWNER, 1000)
      rescue Errno::EPERM
        puts 'Operation not permitted'
        exit(1)
      end
    end

    def set_addr(addr)
      sock_fd = Socket.new(Socket::AF_INET, Socket::SOCK_DGRAM, 0)
      ifr = RubyTun::Ifreq.malloc

      ifr.ifr_name = [@name].pack('a16')
      ifr.iu.ifr_addr[0, 16] = Socket.sockaddr_in(0, addr)
      ifr_size = ifr.to_ptr.size
      flags = ifr[0, ifr_size]
      sock_fd.ioctl(RubyTun::SIOCSIFADDR, flags)
      sock_fd.close
    end

    def set_netmask(netmask)
      sock_fd = Socket.new(Socket::AF_INET, Socket::SOCK_DGRAM, 0)
      ifr = RubyTun::Ifreq.malloc

      ifr.ifr_name = [@name].pack('a16')
      ifr.iu.ifr_addr[0, 16] = Socket.sockaddr_in(0, netmask)
      ifr_size = ifr.to_ptr.size
      flags = ifr[0, ifr_size]
      sock_fd.ioctl(RubyTun::SIOCSIFNETMASK, flags)
      sock_fd.close
    end

    def up
      sock_fd = Socket.new(Socket::AF_INET, Socket::SOCK_DGRAM, 0)
      ifr = RubyTun::Ifreq.malloc
      ifr.ifr_name = [@name].pack('a16')
      ifr.iu.ifr_flags = RubyTun::Up | RubyTun::Running
      ifr_size = ifr.to_ptr.size
      flags = ifr[0, ifr_size]
      sock_fd.ioctl(RubyTun::SIOCSIFFLAGS, flags)
      sock_fd.close
    end

    attr_reader :tun

    def close
      @tun.close if @tun
    end
  end
end

# ========== USAGE EXAMPLE ==========  #

# tun = RubyTun::TunDevice.new("tun0")
# tun.open()
# tun.init()
# tun.set_addr("10.0.0.1")
# tun.set_netmask("255.255.255.0")
# tun.up()
#
# loop do
# p tun.tun.to_io.sysread(1024)
# end

# ==========  USAGE EXAMPLE ==========  #
