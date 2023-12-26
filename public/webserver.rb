module StatusCodes
	SUCCESS = "200 OK"
	BAD_REQUEST = "400 Bad Request"
	UNAUTHORIZED = "401 Unauthorized"
	FORBIDDEN = "403 Forbidden"
	NOT_FOUND = "404 Not Found"
	INTERNAL_ERROR = "500 Internal Server Error"
	BAD_GATEWAY = "502 Bad Gateway"
end

class WebServer
	include StatusCodes
	def initialize(data)
		@data = data
		@http_version = "HTTP/1.1"
		@server_name = "express.js"
		@index_html = File.read("index.html")
	end

	def response
	
		r = "#{@http_version} #{StatusCodes::SUCCESS}\r\n"
		r+= "Connection: close\r\n"
		r+= "Server: #{@server_name}\r\n"
		r+= "\r\n"
		r+= @index_html
		
		return r
	end
end
