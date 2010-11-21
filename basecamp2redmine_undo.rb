#!/usr/bin/env ruby

# This Ruby script will delete all the projects created by basecamp2redmine.rb, based on a Basecamp "backup" XML file.
# See license file and legal note in basecamp2redmine.rb

require 'rubygems'
require 'nokogiri'

filename = ARGV[0] or raise ArgumentError, "Must have filename specified on command line"

x = Nokogiri::XML(File.read filename)
project_ids = x.xpath('//project').map{|p| (p % 'id').content}

puts "# Paste the following Ruby code into script/console, or run through script/runner:"
project_ids.each do |project_id|
  puts %{Project.find_by_identifier("basecamp-p-#{project_id}").destroy}
end
