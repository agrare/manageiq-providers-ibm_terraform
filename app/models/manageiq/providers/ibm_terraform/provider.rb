class ManageIQ::Providers::IbmTerraform::Provider < ::Provider
  has_one :configuration_manager,
          :foreign_key => "provider_id",
          :class_name  => "ManageIQ::Providers::IbmTerraform::ConfigurationManager",
          :dependent   => :destroy,
          :autosave    => true

  has_many :endpoints, :as => :resource, :dependent => :destroy, :autosave => true

  delegate :url,
           :url=,
           :to => :default_endpoint

  virtual_column :url, :type => :string, :uses => :endpoints

  before_validation :ensure_managers

  validates :name, :presence => true, :uniqueness => true
  validates :url,  :presence => true

  def self.description
    @description ||= "Cloud Automation Manager".freeze
  end

  def self.params_for_create
    @params_for_create ||= {
      :fields => [
        {
          :component => 'sub-form',
          :name      => 'endpoints-subform',
          :title     => _("Endpoint"),
          :fields    => [
            {
              :component              => 'validate-provider-credentials',
              :name                   => 'authentications.default.valid',
              :skipSubmit             => true,
              :validationDependencies => %w[type zone_id],
              :fields                 => [
                {
                  :component  => "text-field",
                  :name       => "endpoints.default.url",
                  :label      => _("URL"),
                  :isRequired => true,
                  :validate   => [{:type => "required-validator"}]
                },
                {
                  :component    => "select-field",
                  :name         => "endpoints.default.verify_ssl",
                  :label        => _("SSL verification"),
                  :isRequired   => true,
                  :initialValue => OpenSSL::SSL::VERIFY_PEER,
                  :options      => [
                    {
                      :label => _('Do not verify'),
                      :value => OpenSSL::SSL::VERIFY_NONE,
                    },
                    {
                      :label => _('Verify'),
                      :value => OpenSSL::SSL::VERIFY_PEER,
                    },
                  ]
                },
                {
                  :component  => "text-field",
                  :name       => "authentications.default.userid",
                  :label      => _("Username"),
                  :helperText => _("Should have privileged access, such as root or administrator."),
                  :isRequired => true,
                  :validate   => [{:type => "required-validator"}]
                },
                {
                  :component  => "password-field",
                  :name       => "authentications.default.password",
                  :label      => _("Password"),
                  :type       => "password",
                  :isRequired => true,
                  :validate   => [{:type => "required-validator"}]
                },
              ],
            },
          ],
        },
      ]
    }.freeze
  end

  # Verify Credentials
  # args: {
  #  "endpoints" => {
  #    "default" => {
  #       "url" => nil,
  #       "verify_ssl" => nil
  #    },
  #  },
  #  "authentications" => {
  #     "default" => {
  #       "userid" => nil,
  #       "password" => nil,
  #     }
  #   }
  # }
  def self.verify_credentials(args)
    default_authentication = args.dig("authentications", "default")
    base_url = args.dig("endpoints", "default", "url")
    verify_mode = args.dig("endpoints", "default", "verify_ssl")

    userid   = default_authentication["userid"]
    password = MiqPassword.try_decrypt(default_authentication["password"])

    !!raw_connect(base_url, userid, password, verify_mode)
  end

  def self.raw_connect(base_url, username, password, verify_mode)
    url      = URI.parse(base_url)
    url.port = 8443
    url.path = "/v1/auth/identitytoken"
    use_ssl  = url.scheme == "https"

    require "net/http"
    response = Net::HTTP.start(url.hostname, url.port, :use_ssl => use_ssl, :verify_mode => verify_mode) do |http|
      body    = {
        "grant_type" => "password",
        "username"   => username,
        "password"   => password,
        "scope"      => "openid"
      }

      headers = {"Content-Type" => "application/json"}

      http.post(url, body.to_json, headers)
    end

    "Bearer #{JSON.parse(response.body)["access_token"]}"
  end

  def connect(options = {})
    auth_type = options[:auth_type]
    raise "no credentials defined" if self.missing_credentials?(auth_type)

    verify_ssl = options[:verify_ssl] || self.verify_ssl
    base_url   = options[:url] || url
    username   = options[:username] || authentication_userid(auth_type)
    password   = options[:password] || authentication_password(auth_type)

    self.class.raw_connect(base_url, username, password, verify_ssl)
  end

  def verify_credentials(auth_type = nil, options = {})
    uri = URI.parse(url) unless url.blank?

    !!self.class.raw_connect(url, *auth_user_pwd, false)
  rescue SocketError, Errno::ECONNREFUSED, RestClient::ResourceNotFound, RestClient::InternalServerError => err
    raise MiqException::MiqUnreachableError, err.message, err.backtrace
  rescue RestClient::Unauthorized => err
    raise MiqException::MiqInvalidCredentialsError, err.message, err.backtrace
  end

  private

  def ensure_managers
    build_configuration_manager unless configuration_manager
    configuration_manager.provider = self

    if zone_id_changed?
      configuration_manager.enabled = Zone.maintenance_zone&.id != zone_id
    end
  end
end
