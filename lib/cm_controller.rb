require 'omf_rc'
require 'omf_common'
require 'yaml'

$stdout.sync = true


@config = YAML.load_file('../etc/configuration.yaml')
@auth = @config[:auth]
@xmpp = @config[:xmpp]

module OmfRc::ResourceProxy::CMController
  include OmfRc::ResourceProxyDSL

  register_proxy :cmController

  property :state

  hook :before_ready do |resource|

  end

  configure :state do |res, value|

  end
end


entity_cert = File.expand_path(@auth[:entity_cert])
entity_key = File.expand_path(@auth[:entity_key])
entity = OmfCommon::Auth::Certificate.create_from_x509(File.read(entity_cert), File.read(entity_key))

trusted_roots = File.expand_path(@auth[:root_cert_dir])

OmfCommon.init(:development, communication: { url: "xmpp://#{@xmpp[:username]}:#{@xmpp[:password]}@#{@xmpp[:server]}", auth: {} }) do
  OmfCommon.comm.on_connected do |comm|
    OmfCommon::Auth::CertificateStore.instance.register_default_certs(trusted_roots)
    OmfCommon::Auth::CertificateStore.instance.register(entity, OmfCommon.comm.local_topic.address)
    OmfCommon::Auth::CertificateStore.instance.register(entity)

    info "UserController >> Connected to XMPP server"
    cmContr = OmfRc::ResourceFactory.create(:cmController, { uid: 'cmController', certificate: entity })
    comm.on_interrupted { cmContr.disconnect }
  end
end
