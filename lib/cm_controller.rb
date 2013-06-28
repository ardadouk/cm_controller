require 'omf_rc'
require 'omf_common'
require 'yaml'
require 'open-uri'
require 'nokogiri'


$stdout.sync = true


@config = YAML.load_file('../etc/configuration.yaml')
@auth = @config[:auth]
@xmpp = @config[:xmpp]


module OmfRc::ResourceProxy::CMController
  include OmfRc::ResourceProxyDSL

  register_proxy :cmController

  property :all_nodes, :default => []

  hook :before_ready do |res|
    @config = YAML.load_file('../etc/configuration.yaml')
    @domain = @config[:domain]
    @nodes = @config[:nodes]
    puts "### nodes: #{@nodes}"
    @nodes.each do |node|
      tmp = {node_name: node[0], node_ip: node[1][:ip], node_mac: node[1][:mac], node_cm_ip: node[1][:cm_ip], status: :stopped}
      res.property.all_nodes << tmp
    end
  end

  configure :state do |res, value|
    node = nil
    res.property.all_nodes.each do |n|
      if n[:node_name] == value[:node].to_sym
        node = n
      end
    end
    puts "Node : #{node}"
    if node.nil?
      puts "error: Node nill"
      res.inform(:status, {
                        event_type: "EXIT",
                        exit_code: "-1",
                        msg: "Wrong node name."
                      }, :ALL)
      return
    end

    case value[:status].to_sym
    when :started then res.start_node(node)
    when :stopped then res.stop_node(node)
    when :started_on_pxe then res.start_node_pxe(node)
    when :started_without_pxe then res.start_node_pxe_off(node)
    else
      res.log_inform_warn "Cannot switch node to unknown state '#{value[:status].to_s}'!"
    end

  end

  work("pingable?") do |res, addr|
    output = `ping -c 1 #{addr}`
    !output.include? "100% packet loss"
  end

  work("start_node") do |res, node|
    puts "http://#{node[:node_cm_ip].to_s}/on"
    doc = Nokogiri::XML(open("http://#{node[:node_cm_ip].to_s}/on"))
    puts doc
    sleep 3
    if res.pingable?("#{node[:node_ip].to_s}")
      node[:status] = :started
      res.inform(:status, {
        event_type: "EXIT",
        exit_code: "0",
        msg: "Node is up."
      }, :ALL)
    else
      res.inform(:status, {
        event_type: "EXIT",
        exit_code: "-1",
        msg: "Node is closed."
      }, :ALL)
    end
  end

  work("stop_node") do |res, node|
    puts "http://#{node[:node_cm_ip].to_s}/off"
    doc = Nokogiri::XML(open("http://#{node[:node_cm_ip].to_s}/off"))
    puts doc
    sleep 3
    if !res.pingable?("#{node[:node_ip].to_s}")
      node[:status] = :stopped
      res.inform(:status, {
        event_type: "EXIT",
        exit_code: "0",
        msg: "Node is closed."
      }, :ALL)
    else
      res.inform(:status, {
        event_type: "EXIT",
        exit_code: "-1",
        msg: "Node is up."
      }, :ALL)
    end
  end

  work("reset_node") do |res, node|
    puts "http://#{node[:node_cm_ip].to_s}/reset"
    doc = Nokogiri::XML(open("http://#{node[:node_cm_ip].to_s}/reset"))
    puts doc
  end

  work("start_node_pxe") do |res, node|
    symlink_name = "/tftpboot/pxe-linux.cfg/01-#{node[:node_mac]}"
    if !File.exists?(symlink_name)
      File.symlink("/tftpboot/pxelinux.cfg/omf-5.4", symlink_name)
    end
    if node[:status] == :stopped
      puts "http://#{node[:node_cm_ip].to_s}/on"
      doc = Nokogiri::XML(open("http://#{node[:node_cm_ip].to_s}/on"))
      msg = doc
    elsif node[:status] == :started
      puts "http://#{node[:node_cm_ip].to_s}/reset"
      doc = Nokogiri::XML(open("http://#{node[:node_cm_ip].to_s}/reset"))
      msg = doc
    elsif node[:status] == :started_on_pxe

    end
  end

  work("start_node_pxe_off") do |res, node|
    symlink_name = "/tftpboot/pxe-linux.cfg/01-#{node[:node_mac]}"
    if File.exists?(symlink_name)
      File.delete(symlink_name)
    end

    puts "http://#{node[:node_cm_ip].to_s}/off"
    doc = Nokogiri::XML(open("http://#{node[:node_cm_ip].to_s}/off"))
    puts doc
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

    info "CMController >> Connected to XMPP server"
    cmContr = OmfRc::ResourceFactory.create(:cmController, { uid: 'cmController', certificate: entity })
    comm.on_interrupted { cmContr.disconnect }
  end
end
