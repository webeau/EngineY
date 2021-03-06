#   Copyright 2009-2010 Timothy Fisher
#
#   Licensed under the Apache License, Version 2.0 (the "License");
#   you may not use this file except in compliance with the License.
#   You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
#   Unless required by applicable law or agreed to in writing, software
#   distributed under the License is distributed on an "AS IS" BASIS,
#   WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
#   See the License for the specific language governing permissions and
#   limitations under the License.

require 'digest/sha1'
class User < ActiveRecord::Base
  
  # Virtual attribute for the unencrypted password
  attr_accessor :password
  
  has_one :blog_mirror
  
  has_many :permissions, :dependent => :destroy
  has_many :roles, :through => :permissions 
  
  has_many :memberships, :dependent => :destroy
  has_many :groups, :through => :memberships 
  
  has_many :likes
  
  # TODO: 
  #   Add a condition to only get the attendances set in the future.
  #   Do not get attendances for past events
  has_many :attendances, :foreign_key =>'attendee_id', :dependent => :destroy
  has_many :events, :through => :attendances
   
  has_many :sent_messages, :class_name => 'Message', :foreign_key =>'sender_id', :order=>'created_at DESC'
  has_many :received_messages, :class_name => 'Message', :foreign_key =>'recipient_id', :order=>'created_at DESC'
  has_many :unread_messages, :class_name => 'Message', :foreign_key =>'recipient_id', :conditions => {:read => false} 
  
  has_many :friends, :through => :friendships, :conditions => "status = 'accepted'"
  has_many :requested_friends, :through => :friendships, :source => :friend, :conditions => "status = 'requested'", :order=>"friendships.created_at"
  has_many :pending_friends, :through => :friendships, :source => :friend, :conditions => "status = 'pending'", :order=>"friendships.created_at"
  has_many :friendships, :dependent => :destroy
  
  has_many :followers, :class_name => 'Follow', :foreign_key => 'followee_id', :order => 'created_at DESC'
  has_many :followees, :class_name => 'Follow', :foreign_key => 'follower_id', :order => 'created_at DESC'
  
  belongs_to :state
  belongs_to :country
  has_one :profile_photo, :conditions => [ 'is_profile = ?', true ], :dependent => :destroy
  has_many :photos
  has_many :wall_posts, :order=>'created_at DESC'
  
  has_many :blog_posts, :order=>'created_at DESC'
  has_many :blog_post_topics
  
  has_many :forum_posts, :order=>'created_at DESC'
  has_many :status_posts, :order=>'created_at DESC'
  has_many :rss_feeds
  has_many :announcements
  has_many :book_reviews
  has_many :activities, :order=>'created_at DESC'
  has_many :bug_reports
  has_many :links
  has_many :projects
  has_many :classifieds
  
  validates_presence_of     :login, :email, :first_name, :last_name
  validates_presence_of     :password,                   :if => :password_required?
  validates_presence_of     :password_confirmation,      :if => :password_required?
  validates_length_of       :password, :within => 4..40, :if => :password_required?
  validates_confirmation_of :password,                   :if => :password_required?
  validates_length_of       :login,    :within => 3..40
  validates_length_of       :email,    :within => 3..100
  validates_uniqueness_of   :login, :email, :case_sensitive => false
  validates_length_of       :about_me,  :maximum => 1500, :allow_nil => true
  before_save :encrypt_password
  before_create :make_activation_code 
  # prevents a user from submitting a crafted form that bypasses activation
  # anything else you want your user to change should be added here.
  attr_accessible :id, :login, :email, :first_name, :last_name, :sex, :city, :country_id, 
                  :state, :state_id, :password, :password_confirmation, :website, :blog, 
                  :blog_feed, :about_me, :display_tweets, :twitter_id, :linked_in_url, 
                  :facebook_url, :receive_emails, :last_seen_at, :login_count, :facebook_id,
                  :activated_at, :enabled
  
  # we want the user activity stream message after activating, not after creating
  #after_create :log_activity
  after_create :register_user_to_fb
  
  cattr_reader :per_page
  
  include UserFacebook
  
  @@per_page = 10
  
  
  @@cached_count = nil
 
  def self.cached_count
    @@cached_count ||= User.count(:conditions => "activated_at is not null")
  end
  
  def self.reset_cache
    @@cached_count = nil
  end
  
  
  # Returns the most recent status post made by the user
  def current_status
    if self.status_posts && self.status_posts.length > 0
      return self.status_posts[0]
    end
    nil
  end
  
  
  # Return true if the user likes the activity passed in, otherwise false
  def like_this?(activity)
    @likes = Like.find_likes_cast_by_user(self)
    if @likes
      results = @likes.select{|like| (like.likable_id == activity.id && like.likable_type == 'Activity') }
      if results && results.size > 0
        return true
      end
    end
    return false
  end
  
  
  # Returns the Like object associated with the Activity passed in for this user, if this user 'likes' the activity
  def get_like(activity)
    Like.find_by_user_id_and_likable_id_and_likable_type(self.id, activity.id, 'Activity')
  end
  
  
  # Returns an array of users who have an API key
  def self.with_api_key
    User.find(:all, :conditions => "api_key != '' AND api_key is not null")
  end
  
  
  # Creates a follows relationship between this user and someone he wishes to follow
  def follow(followee_id)
    Follow.create(:follower_id => id,
                  :followee_id => followee_id)
  end
  
  
  def activity_stream(only_statuses, include_friends)
  	if only_statuses && include_friends
  		return friends_status_activity_stream
  	elsif include_friends
  		return friends_activity_stream
  	elsif only_statuses
  		return status_activity_stream
  	else
  		return activities
  	end
  end
  
    
  # Return only activities that represent status posts
  def status_activity_stream
    activities.find_all{|activity| activity.item_type == 'StatusPost' }
  end
  
  
  # Get all activities for the user and his friends
  def friends_activity_stream
    user_ids = self.get_friends_ids
    Activity.find(:all, :conditions => { :user_id => user_ids }, :order=>'created_at DESC')
  end
  
  
  # Get status post activities for the user and his friends
  def friends_status_activity_stream
    user_ids = self.get_friends_ids
    Activity.find(:all, :conditions => {:user_id => user_ids, :item_type=>'StatusPost'}, :order=>'created_at DESC')
  end
  
  
  # Returns an array of friends + self
  def get_friends_ids    
    user_ids = self.friends.map do |friend|
      friend.id
    end
    user_ids << self.id
  end
  
  
  # Retrieve the user's tweets from Twitter
  def fetch_tweets
    begin
      url = "http://twitter.com/statuses/user_timeline/#{twitter_id}.xml"
      if Configuration.USE_PROXY
        xml_data = Net::HTTP::Proxy(Configuration.PROXY_HOST, Configuration.PROXY_PORT).get_response(URI.parse(url)).body
      else
        xml_data = Net::HTTP.get_response(URI.parse(url)).body
      end      
      xml_doc = REXML::Document.new(xml_data)   
      tweets = []
      tweet_count = 0
      xml_doc.elements.each("statuses/status/text") do |element|
        tweet = {}
        # set body and created_at time
        tweet['body'] = EngineyUtil.linkify(element)
        tweet['created_at'] = '7/11/2009'
        tweets.push tweet
        tweet_count = tweet_count + 1
        if tweet_count == Configuration.MAX_TWEETS
          break
        end
      end  
    rescue Errno::ETIMEDOUT
      tweets = []
    end
    tweets
  end
  
  
  # Does the user have an RSS feed for a blog
  def has_blog_feed
    if self.rss_feeds.length > 0
      return true
    else
      return false
    end
  end
  
  
  def name
    if first_name && last_name
      first_name + ' ' + last_name
    elsif first_name
      first_name
    elsif last_name
      last_name
    else
      login
    end
  end
  
  
  def gender
    if sex == 'M'
      'Male'
    elsif sex == 'F'
      'Female'
    else
      ''
    end
  end
  
  
  def self.non_active_users
    User.find(:all, :conditions=>'activated_at IS NULL')
  end
  
  
  def self.male_user_count
    User.count(:conditions=>{:sex=>'M'})
  end
  
  
  def self.female_user_count
    User.count(:conditions=>{:sex=>'F'})
  end
  
  
  def self.most_logins
    User.find(:all, :order => 'login_count DESC')[0]
  end
  
  
  def self.count_with_profile_photo
    Photo.find(:all, 
               :select=>'id, filename, user_id', 
               :conditions=>"is_profile=true AND user_id is NOT NULL AND filename != 'nophoto.png'").size
  end
  
  
  def self.newest
    User.find(:first, :conditions => "activated_at is not null", :order => 'created_at DESC')
  end
  
  
  def set_photo(photo)
    if photo && photo.size != 0 
      # remove old profile photos
      Photo.destroy_all("user_id = " + id.to_s + " AND is_profile = true")
      self.profile_photo = ProfilePhoto.create!(:user_id=>id, 
                                                :is_profile=>true, 
                                                :uploaded_data => photo) 
    end 
  end
  
  
#  def set_temp_photo
#     my_profile_photo = ProfilePhoto.create :is_profile => true, 
#                         :temp_path => File.new(RAILS_ROOT + "/public/images/nophoto.png"), 
#                         :filename => 'nophoto.png', 
#                         :content_type => 'image/png',
#                         :user => self
#     self.profile_photo = my_profile_photo             
#  end
  
  
  # Return pending users
  def self.pending_users
    User.find(:all, :conditions => ['enabled = 0'])
  end
  
  
  # Return the site admins
  def self.admins
    User.find(:all, :conditions => ['role_id = ?', Role.admin.id], :joins => :permissions)
  end
  
  
  # Return the site creators
  def self.creators
    User.find(:all, :conditions => ['role_id = ?', Role.creator.id], :joins => :permissions)
  end
  
  
  def self.admins_and_creators
    User.admins + User.creators
  end
 
  
  def is_creator
    self.roles.each do |role|
      if role.rolename == 'creator'
        return true
      end
    end
    false
  end
  
  
  def is_admin
    self.roles.each do |role|
      if role.rolename == 'administrator' || role.rolename == 'creator'
        return true
      end
    end
    false
  end
  
  
  # Return true if the user has the administrator role
  # or if the user has the group_admin role for the passed in group.
  def is_group_admin(group)
    if is_admin || group.admins.include?(self)
      return true
    end
    false
  end
  
  
  def is_event_owner(event)
    event.user == self
  end
  
  
  def make_site_admin
    Permission.create(:user_id=>self.id, :role_id=>Role.find_by_rolename('administrator').id)
  end
  
  
  def make_group_admin(group_id)
    Permission.create(:user_id=>self.id, :role_id=>Role.find_by_rolename('group_admin').id, :group_id=>group_id)
  end


  # Enables a pending user
  def approve
    self.enabled = true
    save(false)
    log_activity
    User.reset_cache
  end
  
  
  # Activates the user in the database.
  def activate
    @activated = true
    self.activated_at = Time.now.utc
    self.activation_code = nil
    save(false)
    log_activity
    User.reset_cache
  end
  
  
  def active?
    # the existence of an activation code means they have not activated yet
    activation_code.nil?
  end
    
  
  # Authenticates a user by their login name and unencrypted password.  Returns the user or nil.
  def self.authenticate(login, password)
    u = find :first, :conditions => ['login = ? and activated_at IS NOT NULL', login] # need to get the salt
    u && u.authenticated?(password) ? u : nil
  end
  
  
  # Encrypts some data with the salt.
  def self.encrypt(password, salt)
    Digest::SHA1.hexdigest("--#{salt}--#{password}--")
  end
  
  
  # Encrypts the password with the user salt
  def encrypt(password)
    self.class.encrypt(password, salt)
  end
  
  
  def authenticated?(password)
    crypted_password == encrypt(password)
  end
  
  def remember_token?
    remember_token_expires_at && Time.now.utc < remember_token_expires_at 
  end
  
  
  # These create and unset the fields required for remembering users between browser closes
  def remember_me
    remember_me_for 2.weeks
  end
  
  
  def remember_me_for(time)
    remember_me_until time.from_now.utc
  end
  
  def remember_me_until(time)
    self.remember_token_expires_at = time
    self.remember_token = encrypt("#{email}--#{remember_token_expires_at}")
    save(false)
  end
  
  
  def forget_me
    self.remember_token_expires_at = nil
    self.remember_token            = nil
    save(false)
  end
  
  
  # Returns true if the user has just been activated.
  def recently_activated?
    @activated
  end
  
  
  def enable_api!
    self.generate_api_key!
  end
 
 
  def disable_api!
    self.update_attribute(:api_key, "")
  end
 
 
  def api_is_enabled?
    !self.api_key.empty?
  end
 
  
  protected
  
  def secure_digest(*args)
    Digest::SHA1.hexdigest(args.flatten.join('--'))
  end


  def generate_api_key!
    self.update_attribute(:api_key, secure_digest(Time.now, (1..10).map{ rand.to_s }))
  end
  
  
  # before filter 
  def encrypt_password
    return if password.blank?
    self.salt = Digest::SHA1.hexdigest("--#{Time.now.to_s}--#{login}--") if new_record?
    self.crypted_password = encrypt(password)
  end
  
  
  def password_required?
    crypted_password.blank? || !password.blank?
  end
  
  
  def make_activation_code
    self.activation_code = Digest::SHA1.hexdigest( Time.now.to_s.split(//).sort_by {rand}.join )
  end
  
  
  def friend_to_admin
    admin = User.find_by_login('admin')
    unless admin.nil? or admin == self
      Friendship.connect(self, admin)
    end
  end
  
   
  def log_activity
    User.log_activity(self)
  end
  
  
  class << self
    def log_activity(user)
      Activity.create!(:item => user, :user => user)
    end
  end  

  
end
