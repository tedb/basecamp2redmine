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
#
# DATABASE CORRECTION .sql files
# Also, you may need to temporarily delete the following unique index on a join table
# ALTER TABLE `projects_trackers` DROP INDEX `projects_trackers_unique`;
#
# Once you're finished with this import, you can get your unique values/keys with the following SQL statements
# CREATE TABLE `projects_trackers_distinct` SELECT distinct * FROM `projects_trackers`;
# TRUNCATE TABLE `projects_trackers`;
# ALTER TABLE `projects_trackers` ADD UNIQUE KEY `projects_trackers_unique` (`project_id`,`tracker_id`);
# INSERT INTO `projects_trackers` SELECT * FROM `projects_trackers_distinct`;
# DROP TABLE `projects_trackers_distinct`
#
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
# Fork at https://github.com/zeroasterisk/basecamp2redmine # Author: Alan Blount <alan+basecamp2redmine@zeroasterisk.com>
#
# CHANGELOG
# 2010-08-23 Initial public release
# 2010-11-21 Applied bugfix to properly escape quotes
# 2011-08-05 Added methods MyString.clean() and MyString.cleanHtml() to do more string escaping (quotes, interprited special characters, etc) [alan]
# 2011-08-05 Added logical controls for excluding various IDs from import, cleaned up the string cleanup functions, and added before/after SQL files [alan]
# 2011-09-08 Implemented better controls for inclusion/exclusion, Improved checking for existing Item before creation, Pulling in Firm as a Client [alan]
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

# These lengths came from the result of "cd redmine/app/models; grep 'validates_length_of' project.rb issue.rb message.rb board.rb"
PROJECT_NAME_LENGTH = 30
#BOARD_NAME_LENGTH is the same
BOARD_DESCRIPTION_LENGTH = 255
MESSAGE_SUBJECT_LENGTH = 255
ISSUE_SUBJECT_LENGTH = 255

ELLIPSIS = '...'
TRACKER = 'Basecamp Todo'
NAME_APPEND = ' (BC)'

# Include only a few specific Items by ID
# keep empty if you want to include all (works in combination with EXCLUDE)
INCLUDE_ONLY_CLIENT_IDS = [] # eg: [ "1234" , "1235" ] 
INCLUDE_ONLY_PROJECT_IDS = []
INCLUDE_ONLY_TODO_LIST_IDS = []
INCLUDE_ONLY_TODO_IDS = []
INCLUDE_ONLY_POST_IDS = []
# Exclude a few specific Posts by ID
# keep empty if you want to include all (works in combination with INCLUDE_ONLY)
ON_FAILURE_DELETE = false
EXCLUDE_CLIENT_IDS = [] # eg: [ "1234" , "1235" ]
EXCLUDE_PPROJECT_IDS = []
EXCLUDE_TODO_LIST_IDS = []
EXCLUDE_TODO_IDS = []
EXCLUDE_POST_IDS = []
BASECAMP_PARENT_PROJECT_ID = 1 # nil
BASECAMP_COMPANY_NAME_AS_PARENT_PROJECT = true
BASECAMP_COMPANY_NAME_PROJECT_PREFIX = "Basecamp: "
BASECAMP_COMPANY_NAME_PROJECT_PREFIX_SHORT = "BC: "

# -- TODO: File lookups
# could get XML for file attachments and backwards lookup their associations:
# https://%{domain}/projects/%{project_id}/attachments.xml
# https://audiologyonline.basecamphq.com/projects/2231994/attachments.xml

filename = ARGV[0] or raise ArgumentError, "Must have filename specified on command line"


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

# Create several instance methods in String to handle multibyte strings,
# using the Unicode support built into Ruby's regex library
class MyString < String
  # Get the first several *characters* from a string, respecting Unicode
  def my_left(chars)
    raise ArgumentError 'arg must be a number' unless chars.is_a? Numeric
    self.match(/^.{0,#{chars}}/u).to_s
  end
  # Get the last several *characters* from a string, respecting Unicode
  def my_right(chars)
    raise ArgumentError 'arg must be a number' unless chars.is_a? Numeric
    self.match(/.{0,#{chars}}$/u).to_s
  end
  def my_size
    self.gsub(/./u, '.').size
  end
  # Truncate a string from both sides, with an ellipsis in the middle
  # This makes sense for this app, since names are often something like "Project 1, Issue XYZ" and "Project 1, Issue ABC";
  # names are significant at the beginning and end of the string
  def center_truncate(length, ellipsis = '...')
    ellipsis = MyString.new(ellipsis)
    if self.my_size <= length
      return self
    else
      left = self.my_left((length / 2.0).ceil - (ellipsis.my_size / 2.0).floor )
      right = self.my_right((length / 2.0).floor - (ellipsis.my_size / 2.0).ceil )
      return MyString.new(left + ellipsis + right)
    end
  end
  # Escape Other Charcters which have given me problems - <alan+basecamp2redmine@zeroasterisk.com> - 2011.08.04
  def clean()
    string = self
    return MyString.new(string.gsub(/\"/, '').gsub('\\C', '\\\\\\\\C').gsub('\\M', '\\\\\\\\M').gsub('s\\x', 's\\\\\\\\x').strip)
  end
  # Escape Other Charcters which have given me problems - <alan+basecamp2redmine@zeroasterisk.com> - 2011.08.04
  def cleanHTML()
    string = self
    string = string.gsub(/&lt;/, '<').gsub(/&gt;/, '>').gsub(/&amp;/, '&')
    string = string.gsub(/<div[^>]*>/, '').gsub(/<\/div>/, "\n").gsub(/<br ?\/?>/, "\n")
    return MyString.new(string.strip);
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

if (BASECAMP_COMPANY_NAME_AS_PARENT_PROJECT)
  x.xpath('//firm').each do |project|
    name = MyString.new((project % 'name').content).clean()
    short_name = MyString.new(BASECAMP_COMPANY_NAME_PROJECT_PREFIX_SHORT + name).center_truncate(PROJECT_NAME_LENGTH - NAME_APPEND.size, ELLIPSIS).clean()
    short_board_description = MyString.new(BASECAMP_COMPANY_NAME_PROJECT_PREFIX + name).my_left(BOARD_DESCRIPTION_LENGTH).clean()
    id = (project % 'id').content
    goodclient = ((INCLUDE_ONLY_CLIENT_IDS.empty? || INCLUDE_ONLY_CLIENT_IDS.include?(id)) && !EXCLUDE_CLIENT_IDS.include?(id))
    if (goodclient)
      src << %{print "About to create firm as parent project #{id} ('#{short_name}')."}
      src << %{  projects['#{id}'] = Project.find_by_name %{#{short_name}}}
      src << %{  if  projects['#{id}'] == nil}
      src << %{    projects['#{id}'] = Project.new(:name => %{#{short_name}}, :description => %{#{name} (Basecamp)}, :identifier => "basecamp-p-#{id}")}
      src << %{    projects['#{id}'].enabled_module_names = ['issue_tracking', 'boards']}
      src << %{    projects['#{id}'].trackers << BASECAMP_TRACKER}
      src << %{    projects['#{id}'].boards << Board.new(:name => %{#{short_name}#{NAME_APPEND}}, :description => %{#{short_board_description}})}
      src << %{    projects['#{id}'].save!}
      if (BASECAMP_PARENT_PROJECT_ID>0)
        src << %{    projects['#{id}'].set_parent!(#{BASECAMP_PARENT_PROJECT_ID})}
      end
      src << %{    puts " Saved as New Project ID " + projects['#{id}'].id.to_s}
      src << %{  else}
      src << %{    puts " Exists as Project ID " + projects['#{id}'].id.to_s}
      src << %{    if (projects['#{id}'].boards.empty?)}
      src << %{    	 puts " (re-creating boards) "}
      src << %{      projects['#{id}'].boards << Board.new(:name => %{#{short_name}#{NAME_APPEND}}, :description => %{#{short_board_description}})}
      src << %{      projects['#{id}'].save!}
      src << %{    end}
      src << %{  end}
      # TODO add members to project with roles
      # Member.create(:user => u, :project => @target_project, :roles => [role])
    else
      src << %{# Skipping client as parent project #{id} ('#{short_name}').}
    end
  end
  x.xpath('//clients/client').each do |project|
    name = MyString.new((project % 'name').content).clean()
    short_name = MyString.new(BASECAMP_COMPANY_NAME_PROJECT_PREFIX_SHORT + name).center_truncate(PROJECT_NAME_LENGTH - NAME_APPEND.size, ELLIPSIS).clean()
    short_board_description = MyString.new(BASECAMP_COMPANY_NAME_PROJECT_PREFIX + name).my_left(BOARD_DESCRIPTION_LENGTH).clean()
    id = (project % 'id').content
    goodclient = ((INCLUDE_ONLY_CLIENT_IDS.empty? || INCLUDE_ONLY_CLIENT_IDS.include?(id)) && !EXCLUDE_CLIENT_IDS.include?(id))
    if (goodclient)
      src << %{print "About to create client as parent project #{id} ('#{short_name}')."}
      src << %{  projects['#{id}'] = Project.find_by_name %{#{short_name}}}
      src << %{  if  projects['#{id}'] == nil}
      src << %{    projects['#{id}'] = Project.new(:name => %{#{short_name}}, :description => %{#{name} (Basecamp)}, :identifier => "basecamp-p-#{id}")}
      src << %{    projects['#{id}'].enabled_module_names = ['issue_tracking', 'boards']}
      src << %{    projects['#{id}'].trackers << BASECAMP_TRACKER}
      src << %{    projects['#{id}'].boards << Board.new(:name => %{#{short_name}#{NAME_APPEND}}, :description => %{#{short_board_description}})}
      src << %{    projects['#{id}'].save!}
      if (BASECAMP_PARENT_PROJECT_ID>0)
        src << %{    projects['#{id}'].set_parent!(#{BASECAMP_PARENT_PROJECT_ID})}
      end
      src << %{    puts " Saved as New Project ID " + projects['#{id}'].id.to_s}
      src << %{  else}
      src << %{    puts " Exists as Project ID " + projects['#{id}'].id.to_s}
      src << %{    if (projects['#{id}'].boards.empty?)}
      src << %{    	 puts " (re-creating boards) "}
      src << %{      projects['#{id}'].boards << Board.new(:name => %{#{short_name}#{NAME_APPEND}}, :description => %{#{short_board_description}})}
      src << %{      projects['#{id}'].save!}
      src << %{    end}
      src << %{  end}
      # TODO add members to project with roles
      # Member.create(:user => u, :project => @target_project, :roles => [role])
    else
      src << %{# Skipping client as parent project #{id} ('#{short_name}').}
    end
  end
end

x.xpath('//project').each do |project|
  name = MyString.new((project % 'name').content).clean()
  short_name = MyString.new(name).center_truncate(PROJECT_NAME_LENGTH - NAME_APPEND.size, ELLIPSIS).clean()
  short_board_description = MyString.new(name).my_left(BOARD_DESCRIPTION_LENGTH).clean()
  id = (project % 'id').content
  company_id = BASECAMP_PARENT_PROJECT_ID
  if (BASECAMP_COMPANY_NAME_AS_PARENT_PROJECT)
    project.xpath('.//company').each do |company|
      company_id = (company % 'id').content.to_i
    end
  end
  goodproject = ((INCLUDE_ONLY_PROJECT_IDS.empty? || INCLUDE_ONLY_PROJECT_IDS.include?(id)) && !EXCLUDE_PPROJECT_IDS.include?(id))
  if (goodproject)
    src << %{print "About to create project #{id} ('#{short_name}')."}
    src << %{  projects['#{id}'] = Project.find_by_name %{#{short_name}}}
    src << %{  if  projects['#{id}'] == nil}
    src << %{    projects['#{id}'] = Project.new(:name => %{#{short_name}}, :description => %{#{name} (Basecamp)}, :identifier => "basecamp-p-#{id}")}
    src << %{    projects['#{id}'].enabled_module_names = ['issue_tracking', 'boards']}
    src << %{    projects['#{id}'].trackers << BASECAMP_TRACKER}
    src << %{    projects['#{id}'].boards << Board.new(:name => %{#{short_name}#{NAME_APPEND}}, :description => %{#{short_board_description}})}
    src << %{    projects['#{id}'].save!}
    if (company_id>0)
      src << %{    projects['#{id}'].set_parent!(projects['#{company_id}'].id)}
    end
    src << %{    puts " Saved as New Project ID " + projects['#{id}'].id.to_s}
    src << %{  else}
    src << %{    puts " Exists as Project ID " + projects['#{id}'].id.to_s}
    src << %{    if (projects['#{id}'].boards.empty?)}
    src << %{    	 puts " (re-creating boards) "}
    src << %{      projects['#{id}'].boards << Board.new(:name => %{#{short_name}#{NAME_APPEND}}, :description => %{#{short_board_description}})}
    src << %{      projects['#{id}'].save!}
    src << %{    end}
    src << %{  end}
    # TODO add members to project with roles
    # Member.create(:user => u, :project => @target_project, :roles => [role])
  else
    src << %{# Skipping client as parent project #{id} ('#{short_name}').}
  end
end

x.xpath('//todo-list').each do |todo_list|
  name = MyString.new((todo_list % 'name').content).clean()
  short_name = MyString.new(name).center_truncate(ISSUE_SUBJECT_LENGTH, ELLIPSIS).clean()
  id = (todo_list % 'id').content
  description = MyString.new((todo_list % 'description').content).clean()
  parent_project_id = (todo_list % 'project-id').content
  complete = (todo_list % 'complete').content == 'true'
  goodproject = ((INCLUDE_ONLY_PROJECT_IDS.empty? || INCLUDE_ONLY_PROJECT_IDS.include?(parent_project_id)) && !EXCLUDE_PPROJECT_IDS.include?(parent_project_id))
  goodtodolist = ((INCLUDE_ONLY_TODO_LIST_IDS.empty? || INCLUDE_ONLY_TODO_LIST_IDS.include?(id)) && !EXCLUDE_TODO_LIST_IDS.include?(id))
  if (goodproject && goodtodolist)
    src << %{print "About to create todo-list #{id} ('#{short_name}') as Redmine issue under project #{parent_project_id}."}
    src << %{  todo_lists['#{id}'] = Issue.find(:first, :conditions => { :subject => %{#{short_name}}, :project_id => projects['#{parent_project_id}'].id }) }
    src << %{  if  todo_lists['#{id}'] == nil}
    src << %{    todo_lists['#{id}'] = Issue.new(:subject => %{#{short_name}}, :description => %{#{description} (Basecamp ToDoList# #{id})})}
    #:created_on => bug.date_submitted,
    #:updated_on => bug.last_updated
    #i.author = User.find_by_id(users_map[bug.reporter_id])
    #i.category = IssueCategory.find_by_project_id_and_name(i.project_id, bug.category[0,30]) unless bug.category.blank?
    src << %{    todo_lists['#{id}'].status = #{complete} ? CLOSED_STATUS : DEFAULT_STATUS}
    src << %{    todo_lists['#{id}'].tracker = BASECAMP_TRACKER}
    src << %{    todo_lists['#{id}'].author = AUTHOR}
    src << %{    todo_lists['#{id}'].project = projects['#{parent_project_id}']}
    src << %{    todo_lists['#{id}'].save!}
    src << %{    puts " Saved as New Issue ID " + todo_lists['#{id}'].id.to_s}
    src << %{  else}
    src << %{    puts " Exists as Issue ID " + todo_lists['#{id}'].id.to_s}
    src << %{  end}
  else
    EXCLUDE_TODO_LIST_IDS[] = id
    src << %{# Skipping todo list #{id} ('#{short_name}') [in project #{parent_project_id}]}
  end
end

x.xpath('//todo-item').each do |todo_item|
  content = MyString.new((todo_item % 'content').content).clean()
  short_content = MyString.new(content).center_truncate(ISSUE_SUBJECT_LENGTH, ELLIPSIS).clean()
  id = (todo_item % 'id').content
  parent_todo_list_id = (todo_item % 'todo-list-id').content
  complete = (todo_item % 'completed').content == 'true'
  created_at = (todo_item % 'created-at').content
  #completed_at = (todo_item % 'completed-at').content rescue nil
  goodtodolist = ((INCLUDE_ONLY_TODO_LIST_IDS.empty? || INCLUDE_ONLY_TODO_LIST_IDS.include?(parent_todo_list_id)) && !EXCLUDE_TODO_LIST_IDS.include?(parent_todo_list_id))
  goodtodo = ((INCLUDE_ONLY_TODO_IDS.empty? || INCLUDE_ONLY_TODO_IDS.include?(id)) && !EXCLUDE_TODO_IDS.include?(id))
  if (goodtodolist && goodtodo)
    src << %{print "About to create todo #{id} as Redmine sub-issue under issue #{parent_todo_list_id}."}
    src << %{  todos['#{id}'] = Issue.find(:first, :conditions => { :subject => %{#{short_content}}, :parent_id => todo_lists['#{parent_todo_list_id}'].id }) }
    src << %{  if  todos['#{id}'] == nil}
    src << %{    todos['#{id}'] = Issue.new :subject => %{#{short_content}}, :description => %{#{content} (Basecamp ToDo# #{id})}, :created_on => '#{created_at}' }
    #:completed_at => '#{completed_at}'
    #i.category = IssueCategory.find_by_project_id_and_name(i.project_id, bug.category[0,30]) unless bug.category.blank?
    src << %{    todos['#{id}'].status = #{complete} ? CLOSED_STATUS : DEFAULT_STATUS}
    src << %{    todos['#{id}'].tracker = BASECAMP_TRACKER}
    src << %{    todos['#{id}'].author = AUTHOR}
    src << %{    todos['#{id}'].project = todo_lists['#{parent_todo_list_id}'].project}
    src << %{    todos['#{id}'].parent_issue_id = todo_lists['#{parent_todo_list_id}'].id}
    src << %{    todos['#{id}'].save!}
    src << %{    puts " Saved as Issue ID " + todos['#{id}'].id.to_s}
    src << %{  else}
    src << %{    puts " Exists as Issue ID " + todos['#{id}'].id.to_s}
    src << %{  end}
  else
    src << %{# Skipping todo list #{id} ('#{short_content}') [in parent_todo_list_id #{parent_todo_list_id}]}
  end
end

x.xpath('//post').each do |post|
  body = MyString.new((post % 'body').content).clean().cleanHTML()
  message_reply_prefix = 'Re: '
  title = MyString.new((post % 'title').content).clean().cleanHTML()
  short_title = MyString.new(title).center_truncate(MESSAGE_SUBJECT_LENGTH - message_reply_prefix.size, ELLIPSIS)
  id = (post % 'id').content
  parent_project_id = (post % 'project-id').content
  author_name = MyString.new((post % 'author-name').content).clean()
  posted_on = (post % 'posted-on').content
  goodproject = ((INCLUDE_ONLY_PROJECT_IDS.empty? || INCLUDE_ONLY_PROJECT_IDS.include?(parent_project_id)) && !EXCLUDE_PPROJECT_IDS.include?(parent_project_id))
  goodpost = ((INCLUDE_ONLY_POST_IDS.empty? || INCLUDE_ONLY_POST_IDS.include?(id)) && !EXCLUDE_POST_IDS.include?(id))
  if (goodproject && goodpost)
    src << %{print "About to create post #{id} as Redmine message under project #{parent_project_id}."}
    src << %{  messages['#{id}'] = Message.find(:first, :include => [:board], :conditions => { :subject => %{#{short_title}}, :boards => { :id => projects['#{parent_project_id}'].boards.first.id } } ) }
    src << %{  if  messages['#{id}'] == nil}
    src << %{    messages['#{id}'] = Message.new :board => projects['#{parent_project_id}'].boards.first,
    :subject => %{#{short_title}}, :content => %{#{body}\\n\\n-- \\n#{author_name}},
    :created_on => '#{posted_on}', :author => AUTHOR }
    #:completed_at => '#{completed_at}'
    #src << %{    messages['#{id}'].author = AUTHOR}
    src << %{    messages['#{id}'].save!}
    src << %{    puts " Saved as Message ID " + messages['#{id}'].id.to_s}
    src << %{  else}
    src << %{    puts " Exists as Message ID " + messages['#{id}'].id.to_s}
    src << %{  end}
    # Nested comments
    post.xpath('.//comment[commentable-type = "Post"]').each do |comment|
      comment_body = MyString.new((comment % 'body').content).clean().cleanHTML()
      comment_id = (comment % 'id').content
      parent_message_id = (comment % 'commentable-id').content
      comment_author_name = MyString.new((comment % 'author-name').content).clean()
      comment_created_at = (comment % 'created-at').content
      
      src << %{print "About to create post comment #{comment_id} as Redmine sub-message under " + messages['#{id}'].id.to_s + " project #{parent_project_id}."}
      src << %{  comments['#{id}'] = Message.find(:first, :include => [:board], :conditions => { :subject => %{#{message_reply_prefix}#{short_title}}, :parent_id => messages['#{id}'].id, :created_on => %{#{comment_created_at}}, :boards => { :project_id => projects['#{parent_project_id}'].id } } ) }
      src << %{  if  comments['#{id}'] == nil}
      src << %{    comments['#{comment_id}'] = Message.new(:board => projects['#{parent_project_id}'].boards.first,
      :subject => %{#{message_reply_prefix}#{short_title}}, :content => %{#{comment_body}\\n\\n-- \\n#{comment_author_name}},
      :created_on => '#{comment_created_at}', :author => AUTHOR, :parent => messages['#{id}'] )}
      src << %{    comments['#{comment_id}'].save!}
      src << %{    puts " Saved comment as Message ID " + comments['#{comment_id}'].id.to_s}
      src << %{  else}
      src << %{    puts " Exists comment as Message ID " + comments['#{id}'].id.to_s}
      src << %{  end}
    end
  else
    src << %{# Skipping post #{id} ('#{short_title}') [in project #{parent_project_id}]}
  end
end

src << %{puts "\\n\\n-----------\\nUndo Script\\n-----------\\nTo undo this import, run script/console and paste in this Ruby code.  This will delete only the projects created by the import process.\\n\\n"}

src << %{rescue => e}
src << %{  file = e.backtrace.grep /\#{File.basename(__FILE__)}/}
src << %{  puts "\\n\\nException was raised at \#{file}." }

if (ON_FAILURE_DELETE)
	#src << %{  puts "\\nDeleting all referenced projects!" }
	# don't actually need to delete all the objects individually; deleting the project will cascade deletes
	src << %{puts '[' + projects.values.map(&:id).map(&:to_s).join(',') + '].each   { |i| Project.destroy i }'}
	src << %{  projects.each_value do |p| p.destroy unless p.new_record?; end }
	# More verbose BUT more clear...
	#src << %{puts journals.values.map{|p| "Journal.destroy " + p.id.to_s}.join("; ")}
	#src << %{puts todos.values.map{|p| "Issue.destroy " + p.id.to_s}.join("; ")}
	#src << %{puts todo_lists.values.map{|p| "Issue.destroy " + p.id.to_s}.join("; ")}
	#src << %{puts projects.values.map{|p| "Project.destroy " + p.id.to_s}.join("; ")}
end


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