#!/usr/bin/env ruby

# This Ruby script will extract data from a Basecamp "backup" XML file and import
# it into Redmine.
#
# You must install the Nokogiri gem, which is an XML parser: sudo gem install nokogiri
#
# This script is a "code generator", in that it writes a new Ruby script to STDOUT.
# This script contains invocations of Redmine's ActiveRecord models.  The resulting
# "import script" can be edited before being executed, if desired. 
#
# Before running this script, you must create a Tracker inside Redmine called "Basecamp Todo".
# You do not need to associate it with any existing projects.
#
# This script, if saved as filename basecamp2redmine.rb, can be invoked as follows.
# This will generate an ActiveRecord-based import script in the current directory,
# which should be the root directory of the Redmine installation.
#
# ruby basecamp2redmine.rb my-basecamp-backup.xml > basecamp-import.rb
# script/runner -e development basecamp-import.rb
#
# The import process can be reversed by running:
#
# ruby basecamp2redmine_undo.rb my-basecamp-backup.xml > basecamp-undo.rb
# script/runner -e development basecamp-undo.rb
#
# Author: Ted Behling <ted@tedb.us>
# Available at http://gist.github.com/tedb
# 
# CHANGELOG
# 2010-08-23 Initial public release
# 2010-11-21 Applied bugfix to properly escape quotes
#
# Thanks to Tactio Interaction Design (www.tactio.com.br) for funding this work!
#
# See MIT License below.  You are not required to provide the author with changes
# you make to this software, but it would be appreciated, as a courtesy, if it is possible.
#
# LEGAL NOTE:
# The Basecamp name is a registered trademark of 37 Signals, LLC.  Use of this trademark
# is for reference only, and does not imply any relationship or affiliation with or endorsement
# from or by 37 Signals, LLC.
# Ted Behling, the author of this script, has no affiliation with 37 Signals, LLC.
# All source code contained in this file is the original work of Ted Behling.
# Product names, logos, brands, and other trademarks featured or referred to within
# this software are the property of their respective trademark holders.
# 37 Signals does not sponsor or endorse this script or its author.
#
# DHH, please don't sue me for trademark infringement.  I don't have anything you'd want anyway.
#

require 'rubygems'
require 'nokogiri'

PROJECT_NAME_LENGTH = 30 - 5
TRACKER = 'Basecamp Todo'

filename = ARGV[0] or raise ArgumentError, "Must have filename specified on command line"

def truncate_name(name, length, ellipsis)
  name.size <= length ? name : name[0..length / 2 - 1] + ellipsis + name[-(length/2 - 2)..-1]
end

# Hack Nokogiri to escape our curly braces for us
# This script delimits strings with curly braces so it's a little easier to think about quoting in our generated code
module Nokogiri
  module XML
    class Node
      alias :my_original_content :content
      def content(*args)
        # Escape { and } with \
        my_original_content(*args).gsub(/\{|\}/, '\\\\\0')
      end
    end
  end
end

src = []
src << %{projects = {}}
src << %{todo_lists = {}} # Todo lists are actually tasks that have sub-tasks --- was sub-projects
src << %{todos = {}}
src << %{journals = {}}
src << %{messages = {}}
src << %{comments = {}}

src << %{BASECAMP_TRACKER = Tracker.find_by_name '#{TRACKER}'}
src << %{raise "Tracker named '#{TRACKER}' must exist" unless BASECAMP_TRACKER}

src << %{DEFAULT_STATUS = IssueStatus.default}
src << %{CLOSED_STATUS = IssueStatus.find :first, :conditions => { :is_closed => true }}
src << %{AUTHOR = User.anonymous  #User.find 1}

src << %{begin}

x = Nokogiri::XML(File.read filename)
x.xpath('//project').each do |project|
  name = (project % 'name').content
  short_name = truncate_name(name, PROJECT_NAME_LENGTH, '...')
  id = (project % 'id').content
  
  src << %{print "About to create project #{id} ('#{short_name}')..."}
  src << %{  projects['#{id}'] = Project.new(:name => %{#{short_name}}, :description => %{#{name} (Basecamp)}, :identifier => "basecamp-p-#{id}")}
  src << %{  projects['#{id}'].enabled_module_names = ['issue_tracking', 'boards']}
  src << %{  projects['#{id}'].trackers << BASECAMP_TRACKER}
  src << %{  projects['#{id}'].boards << Board.new(:name => %{#{short_name} (BC)}, :description => %{#{name}})}
  src << %{  projects['#{id}'].save!}
  src << %{puts " Saved as Issue ID " + projects['#{id}'].id.to_s}
  
  # TODO add members to project with roles
  # Member.create(:user => u, :project => @target_project, :roles => [role])
end

x.xpath('//todo-list').each do |todo_list|
  name = (todo_list % 'name').content
  #short_name = truncate_name(name, PROJECT_NAME_LENGTH, '...')
  id = (todo_list % 'id').content
  description = (todo_list % 'description').content
  parent_project_id = (todo_list % 'project-id').content
  complete = (todo_list % 'complete').content == 'true'
  
# Commented because we don't want Todo Lists created as Sub-Projects.  Using Sub-Tasks instead.
#  src << %{print "About to create todo-list #{id} ('#{short_name}') as sub-project of #{parent_project_id}..."}
#  src << %{  todo_lists['#{id}'] = Project.new(:name => '#{short_name} (BC)', :description => "#{name}#{description.size > 0 ? "\n\n" + description : ''}", :identifier => "basecamp-tl-#{id}")}
#  src << %{  todo_lists['#{id}'].enabled_module_names = ['issue_tracking']}
#  src << %{  todo_lists['#{id}'].trackers << BASECAMP_TRACKER}
#  src << %{  todo_lists['#{id}'].save!}
#  src << %{  projects['#{parent_project_id}'].children << todo_lists['#{id}']}
#  src << %{  projects['#{parent_project_id}'].save!}
#  src << %{puts " Saved."}

  src << %{print "About to create todo-list #{id} ('#{name}') as Redmine issue under project #{parent_project_id}..."}
  src << %{    todo_lists['#{id}'] = Issue.new :subject => %{#{name}}, :description => %{#{description}}}
                #:created_on => bug.date_submitted,
                #:updated_on => bug.last_updated
  #i.author = User.find_by_id(users_map[bug.reporter_id])
  #i.category = IssueCategory.find_by_project_id_and_name(i.project_id, bug.category[0,30]) unless bug.category.blank?
  src << %{    todo_lists['#{id}'].status = #{complete} ? CLOSED_STATUS : DEFAULT_STATUS}
  src << %{    todo_lists['#{id}'].tracker = BASECAMP_TRACKER}
  src << %{    todo_lists['#{id}'].author = AUTHOR}
  src << %{    todo_lists['#{id}'].project = projects['#{parent_project_id}']}
  src << %{    todo_lists['#{id}'].save!}
  src << %{puts " Saved as Issue ID " + todo_lists['#{id}'].id.to_s}
end

x.xpath('//todo-item').each do |todo_item|
  content = (todo_item % 'content').content
  id = (todo_item % 'id').content
  parent_todo_list_id = (todo_item % 'todo-list-id').content
  complete = (todo_item % 'completed').content == 'true'
  created_at = (todo_item % 'created-at').content
  #completed_at = (todo_item % 'completed-at').content rescue nil
  
  src << %{print "About to create todo #{id} as Redmine sub-issue under issue #{parent_todo_list_id}..."}
  src << %{    todos['#{id}'] = Issue.new :subject => %{#{content[0..255]}}, :description => %{#{content}},
                :created_on => '#{created_at}' }
                #:completed_at => '#{completed_at}'
  #i.category = IssueCategory.find_by_project_id_and_name(i.project_id, bug.category[0,30]) unless bug.category.blank?
  src << %{    todos['#{id}'].status = #{complete} ? CLOSED_STATUS : DEFAULT_STATUS}
  src << %{    todos['#{id}'].tracker = BASECAMP_TRACKER}
  src << %{    todos['#{id}'].author = AUTHOR}
  src << %{    todos['#{id}'].project = todo_lists['#{parent_todo_list_id}'].project}
  src << %{    todos['#{id}'].parent_issue_id = todo_lists['#{parent_todo_list_id}'].id}
  src << %{    todos['#{id}'].save!}
  src << %{puts " Saved as Issue ID " + todos['#{id}'].id.to_s}
end

x.xpath('//post').each do |post|
  # Convert some HTML tags
  body = (post % 'body').content.gsub(/&lt;/, '<').gsub(/&gt;/, '>').gsub(/&amp;/, '&')
  body.gsub!(/<div[^>]*>/, '')
  body.gsub!(/<\/div>/, "\n")
  body.gsub!(/<br ?\/?>/, "\n")
  
  title = (post % 'title').content
  id = (post % 'id').content
  parent_project_id = (post % 'project-id').content
  author_name = (post % 'author-name').content
  posted_on = (post % 'posted-on').content
  
  src << %{print "About to create post #{id} as Redmine message under project #{parent_project_id}..."}
  src << %{    messages['#{id}'] = Message.new :board => projects['#{parent_project_id}'].boards.first,
                :subject => %{#{title}}, :content => %{#{body}\\n\\n-- \\n#{author_name}},
                :created_on => '#{posted_on}', :author => AUTHOR }
                #:completed_at => '#{completed_at}'
  #src << %{    messages['#{id}'].author = AUTHOR}
  src << %{    messages['#{id}'].save!}
  src << %{puts " Saved as Message ID " + messages['#{id}'].id.to_s}
  
  post.xpath('.//comment[commentable-type = "Post"]').each do |comment|
    # Convert some HTML tags
    comment_body = (comment % 'body').content.gsub(/&lt;/, '<').gsub(/&gt;/, '>').gsub(/&amp;/, '&')
    comment_body.gsub!(/<div[^>]*>/, '')
    comment_body.gsub!(/<\/div>/, "\n")
    comment_body.gsub!(/<br ?\/?>/, "\n")
    
    comment_id = (comment % 'id').content
    parent_message_id = (comment % 'commentable-id').content
    comment_author_name = (comment % 'author-name').content
    comment_created_at = (comment % 'created-at').content
    
    src << %{print "About to create post comment #{comment_id} as Redmine sub-message under project #{parent_project_id}..."}
    src << %{    comments['#{comment_id}'] = Message.new :board => projects['#{parent_project_id}'].boards.first,
                  :subject => %{Re: #{title}}, :content => %{#{comment_body}\\n\\n-- \\n#{comment_author_name}},
                  :created_on => '#{comment_created_at}', :author => AUTHOR, :parent => messages['#{id}'] }
    src << %{    comments['#{comment_id}'].save!}
    src << %{puts " Saved comment as Message ID " + comments['#{comment_id}'].id.to_s}
  end
end

  src << %{puts "\\n\\n-----------\\nUndo Script\\n-----------\\nTo undo this import, run script/console and paste in this Ruby code.  This will delete only the projects created by the import process.\\n\\n"}

# don't actually need to delete all the objects individually; deleting the project will cascade deletes
#src << %{puts '[' + journals.values.map(&:id).map(&:to_s).join(',') + '].each   { |i| Journal.destroy i }'}
#src << %{puts '[' + todos.values.map(&:id).map(&:to_s).join(',') + '].each      { |i| Issue.destroy i }'}
#src << %{puts '[' + todo_lists.values.map(&:id).map(&:to_s).join(',') + '].each { |i| Issue.destroy i }'}
src << %{puts '[' + projects.values.map(&:id).map(&:to_s).join(',') + '].each   { |i| Project.destroy i }'}

# More verbose BUT more clear...
#src << %{puts journals.values.map{|p| "Journal.destroy " + p.id.to_s}.join("; ")}
#src << %{puts todos.values.map{|p| "Issue.destroy " + p.id.to_s}.join("; ")}
#src << %{puts todo_lists.values.map{|p| "Issue.destroy " + p.id.to_s}.join("; ")}
#src << %{puts projects.values.map{|p| "Project.destroy " + p.id.to_s}.join("; ")}

src << %{rescue => e}
src << %{  file = e.backtrace.grep /\#{File.basename(__FILE__)}/}
src << %{  puts "\\n\\nException was raised at \#{file}; deleting all imported projects..." }

#src << %{  journals.each_value do |j| j.destroy unless j.new_record?; end }
#src << %{  todos.each_value do |t| t.destroy unless t.new_record?; end }
#src << %{  todo_lists.each_value do |t| t.destroy unless t.new_record?; end }
src << %{  projects.each_value do |p| p.destroy unless p.new_record?; end }

src << %{  raise e}
src << %{end}


puts src.join "\n"

__END__

-------
Nokogiri usage note:
doc.xpath('//h3/a[@class="l"]').each do |link|
 puts link.content
end
-------

The MIT License

Copyright (c) 2010 Ted Behling

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in
all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
THE SOFTWARE.