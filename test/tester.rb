require 'omf_common'

entity = OmfCommon::Auth::Certificate.create_from_x509(File.read("/home/ardadouk/.omf/urc.pem"),
                                                       File.read("/home/ardadouk/.omf/user_rc_key.pem"))

OmfCommon.init(:development, communication: { url: 'xmpp://beta:1234@localhost' , auth: {}}) do
  OmfCommon.comm.on_connected do |comm|
    OmfCommon::Auth::CertificateStore.instance.register_default_certs("/home/ardadouk/.omf/trusted_roots/")
    OmfCommon::Auth::CertificateStore.instance.register(entity, OmfCommon.comm.local_topic.address)
    OmfCommon::Auth::CertificateStore.instance.register(entity)

    info "Test script >> Connected to XMPP"

    comm.subscribe('cmController') do |controller|
      unless controller.error?
        controller.configure(state: {node: :node107, status: :started})
        sleep 20
        controller.configure(state: {node: :node107, status: :stopped})
      else
        error controller.inspect
      end
    end

    #OmfCommon.eventloop.after(20) { comm.disconnect }
    comm.on_interrupted { comm.disconnect }
  end
end
