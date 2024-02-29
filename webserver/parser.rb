module HttpParser

	def parse(req)
		req.downcase!
		lines = req.split("\r\n")
		first_line = lines[0]
		first_line_split = first_line.split(" ")
		method	= first_line_split[0]
		path 		= first_line_split[1]
		headers = lines[1..-1]
		
		req.define_singleton_method(:path) { return path }
		req.define_singleton_method(:method) { return method }
		req.define_singleton_method(:headers) { return headers }
	end

end
