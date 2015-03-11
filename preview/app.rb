require 'nokogiri'
require 'aws-sdk'
require 'sinatra'
require 'json'
require 'base64'
require 'mini_magick'
require 'dotenv'
Dotenv.load

class Parser

	def initialize(args={})
		@compress_images  = args[:compress_images]
		@compress_quality = args[:compress_quality] || 70
	end

	def input_file
		ARGV.first
	end

	def doc
		@doc ||= Nokogiri::HTML(File.open(input_file, 'r').read)
	end

	def artboard_ids
		doc.css('.g-artboard').map{|el| el.attr('id') }
	end

	def artboard_widths
		artboard_ids.map{|id| id.split('-').last.to_i }
	end

	def project_slug
		artboard_ids.first.split('-')[1..-2].join('-')
	end

	def exported_css
		# don't pull global styles, only <style> blocks inside artboards		
		doc.css(
			artboard_ids.map{|id| "##{id} style"}.join(", ")
		).map(&:text)
	end

	# def upload(options={})		
	# 	Aws::S3::Client.new(region: 'us-east-1', access_key_id: ENV['S3_KEY'], secret_access_key: ENV['S3_SECRET'])
	# 		.put_object(
	# 			bucket: ENV['S3_BUCKET'],
	# 			key: options[:key],
	# 			body: options[:contents],
	# 			acl: 'public-read',
	# 			content_type: options[:content_type],
	# 			cache_control: "public, max_age=5"
	# 		)
	#   	"//s3.amazonaws.com/#{ENV['S3_BUCKET']}/#{options[:key]}"
	# end

	# def upload_image(src)	
	# 	# TK
	# 	path = File.join(Pathname.new(input_file).dirname, src)
	# 	puts "uploading #{path}"
	# 	return upload({
	# 		key: "ai2html/#{project_slug()}/#{src}",
	# 		content_type: "image/jpg",
	# 		contents: File.open(path, 'rb').read
	# 	})
	# end

	def images
		doc.css('img').map do |img| 
			{ id: img.attr('id'), src: img.attr('src') }
		end
	end

	def artboard_sizes
		artboard_widths.map(&:to_i).sort + [nil]
	end

	# def replace_images
	# 	# TK
	# 	images.map do |image|	
	# 		image.merge({ uploaded_src: upload_image(image[:src]) })
	# 	end.each do |image|
	# 		doc.css("##{image[:id]}").attr('src', image[:uploaded_src])
	# 	end
	# end

	def css
		parts = [] << exported_css()
		
		artboard_ids.each do |artboard_id|
			parts << "##{artboard_id} { display: none; }"
		end	

		parts << artboard_sizes.each_cons(2).to_a.map do |min, max|
			[     "@media only screen",
				 " and (min-width: #{min+1}px)",
				(" and (max-width: #{max}px)" if !max.nil?),
			].compact.join("") + " {
				#g-#{project_slug}-#{min} {
					display: block;
				}
			}"
		end

		parts.join("\n")
	end

	def artboard_html_only
		html = artboard_ids.map{|artboard| doc.css("##{artboard}").to_html }.join("\n\n")
		temp_doc = Nokogiri::HTML.fragment(html)
		temp_doc.css('style').remove()
		temp_doc.to_html()
	end

	def inline_images!
		# Base64 encode all of the background images and data-uri them into each <img>
		# TODO: should be about to do this in parallel
		images.each do |image|
			source_path = File.join(
				Pathname.new(Parser.new.input_file).dirname, 
				image[:src]
			)
			
			if @compress_images == true # conditional :(
				final_path = Tempfile.new('ai-resize')
				MiniMagick::Image.open(source_path)
					.auto_orient			
					.strip
					.quality(@compress_quality)	
					.write(final_path)
				puts "wrote #{final_path} for #{source_path} at quality #{@compress_quality}"
			else
				# if you don't compress the images and you're using high res stuff...
				# it'll probably be a very big JS file. like 5+ megs
				final_path = source_path
			end

			binary_contents = File.open(final_path, 'rb').read
			base64_contents = Base64.encode64(binary_contents).gsub("\n", "")
			doc.css("##{image[:id]}").attr('src', "data:image/jpg;base64,#{base64_contents}") # TK: not always jpg!
		end
	end

end

get '/' do
	@project_slug = Parser.new.project_slug
	erb :index
end

get '/embed.js' do
	@parser = Parser.new(compress_images: true, compress_quality: 50)	
	@parser.inline_images!
	content_type 'text/javascript'
	erb :embed
end

get '/*.*' do
	# catch the static asset request for artboard backgrounds and serve. 
	# if you're not using inline_images!, this will serve the background <img> tags in development, 
	# but you'll need to manually deploy them in production
	send_file File.join(
		Pathname.new(Parser.new.input_file).dirname, 
		request.path
	)
end

`open http://127.0.0.1:4567`