require "erb"
require_relative "codes"
require_relative "parser"
include StatusCodes
include HttpParser

class WebServer

  def initialize(req)
    @req = req
    @res = nil
    @http_version = 'HTTP/1.1'
    @server_name = 'express.js'
    @path = Dir.pwd + '/webserver' + '/public'
    @static_files = Dir.entries(@path + '/static').map{|p| '/static/' + p}
    
    @general_headers = {
    	"Strict-Transport-Security" => "max-age=31536000; includeSubDomains",
    	"Content-Security-Policy" => "script-src 'self'",
    	"X-Frame-Options" => "SAMEORIGIN",
    	"X-Content-Type-Options" => "nosniff",
    	"Referrer-Policy" => "no-referrer",
    	"Connection" => "close",
    	"Server" => @server_name
    }
    
    @html_headers = {
    	"Content-Type" => "text/html; charset=utf-8",
    }.merge(@general_headers)
    
    @css_headers = {
    	"Content-Type" => "text/css; charset=utf-8",
    }.merge(@general_headers)
    
  end

	def parse()
		HttpParser::parse(@req)
	end

	def route_get()
		# get methods handling
		# loading the components
		header = ERB.new(File.read("#{@path}/components/header.rhtml")).result(binding)
		footer = ERB.new(File.read("#{@path}/components/footer.rhtml")).result(binding)
		case @req.path
		when *@static_files
			unless File.exists?("#{@path}/#{@req.path}")
				# 404 not found
				body = ERB.new(File.read("#{@path}/not_found.rhtml"))
				@res = "#{@http_version} #{StatusCodes::NOT_FOUND}\r\n"
				@res += @html_headers.map{|k, v| "#{k}: #{v}\r\n"}.join
				@res += "\r\n"
				@res += body.result(binding)
				return
			end
			@res = "#{@http_version} #{StatusCodes::SUCCESS}\r\n"
			@res += @css_headers.map{|k, v| "#{k}: #{v}\r\n"}.join
			@res += "\r\n"
			@res += File.read("#{@path}/#{@req.path}")
			
		when "/"
			body = ERB.new(File.read("#{@path}/index.rhtml"))
			@res = "#{@http_version} #{StatusCodes::SUCCESS}\r\n"
			@res += @html_headers.map{|k, v| "#{k}: #{v}\r\n"}.join
			@res += "\r\n"
			@res += body.result(binding)
		when "/login"
			body = ERB.new(File.read("#{@path}/login.rhtml"))
			@res = "#{@http_version} #{StatusCodes::SUCCESS}\r\n"
			@res += @html_headers.map{|k, v| "#{k}: #{v}\r\n"}.join
			@res += "\r\n"
			@res += body.result(binding)
		when "/register"
			body = ERB.new(File.read("#{@path}/register.rhtml"))
			@res = "#{@http_version} #{StatusCodes::SUCCESS}\r\n"
			@res += @html_headers.map{|k, v| "#{k}: #{v}\r\n"}.join
			@res += "\r\n"
			@res += body.result(binding)
		else
			# 404 not found
			body = ERB.new(File.read("#{@path}/not_found.rhtml"))
			@res = "#{@http_version} #{StatusCodes::NOT_FOUND}\r\n"
			@res += @html_headers.map{|k, v| "#{k}: #{v}\r\n"}.join
			@res += "\r\n"
			@res += body.result(binding)
		end
	end

	def route_post()
		# post req handling
	end

	def route_unknown()
		# unknown methods handling
		body = ERB.new(File.read("#{@path}/bad_request.rhtml"))
		@res = "#{@http_version} #{StatusCodes::BAD_REQUEST}\r\n"
		@res += @html_headers.map{|k, v| "#{k}: #{v}\r\n"}.join
		@res += "\r\n"
		@res += body.result(binding)
	end

	def route()
		case @req.method
			when "get"
				route_get()
			when "post"
				route_post()
			else
				route_unknown()
		end
	end
	
  def response
  	parse()
  	route()
  	return @res
  end
end
