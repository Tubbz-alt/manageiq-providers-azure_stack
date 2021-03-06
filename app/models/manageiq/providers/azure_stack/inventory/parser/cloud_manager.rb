class ManageIQ::Providers::AzureStack::Inventory::Parser::CloudManager < ManageIQ::Providers::AzureStack::Inventory::Parser
  def parse
    log_header = "Collecting data for EMS : [#{collector.manager.name}] id: [#{collector.manager.id}]"
    $azure_stack_log.info("#{log_header}...")

    resource_groups
    availability_zones
    flavors
    vms

    $azure_stack_log.info("#{log_header}...Complete")
  end

  def resource_groups
    collector.resource_groups.each do |resource_group|
      persister.resource_groups.build(
        :name    => resource_group.name,
        :ems_ref => resource_group.id.downcase
      )
    end
  end

  def availability_zones
    persister.availability_zones.build(
      :ems_ref => 'default',
      :name    => persister.manager.name
    )
  end

  def flavors
    collector.flavors.each do |flavor|
      persister.flavors.build(
        :ems_ref        => flavor.name.downcase,
        :name           => flavor.name,
        :cpus           => flavor.number_of_cores,
        :cpu_cores      => flavor.number_of_cores / vcpus_per_socket(flavor.name),
        :memory         => flavor.memory_in_mb.megabytes,
        :root_disk_size => flavor.os_disk_size_in_mb.megabytes,
        :swap_disk_size => flavor.resource_disk_size_in_mb.megabytes,
        :enabled        => true
      )
    end
  end

  def vms
    collector.vms.each do |vm|
      uid = vm.id.downcase
      flavor_ref = vm.hardware_profile.vm_size.downcase

      power_state = 'unknown' unless (power_state = collector.raw_power_state(vm.instance_view))

      vm_obj = persister.vms.build(
        :name              => vm.name,
        :ems_ref           => uid,
        :uid_ems           => uid,
        :vendor            => 'azure_stack',
        :connection_state  => 'connected',
        :raw_power_state   => power_state,
        :location          => vm.location,
        :availability_zone => persister.availability_zones.lazy_find('default'),
        :resource_group    => persister.resource_groups.lazy_find(collector.resource_group_id(vm.id)),
        :flavor            => persister.flavors.lazy_find(flavor_ref)
      )

      persister.operating_systems.build(
        :vm_or_template => vm_obj,
        :product_name   => guest_os(vm)
      )

      persister.hardwares.build(
        :vm_or_template  => vm_obj,
        :cpu_sockets     => persister.flavors.lazy_find(flavor_ref, :key => :cpu_cores),
        :cpu_total_cores => persister.flavors.lazy_find(flavor_ref, :key => :cpus),
        :memory_mb       => persister.flavors.find(flavor_ref).memory,
        :disk_capacity   => persister.flavors.lazy_find(flavor_ref, :key => :swap_disk_size)
      )
    end
  end

  # Fetch full OS info from image (e.g. 'UbuntuServer 16.04 LTS'), fallback to basic info (e.g. 'Linux').
  def guest_os(vm)
    if (image_reference = vm.storage_profile&.image_reference) && image_reference&.offer
      "#{image_reference.offer} #{image_reference.sku.tr('-', ' ')}"
    else
      vm.storage_profile.os_disk.os_type
    end
  end

  def vcpus_per_socket(flavor_name)
    # https://docs.microsoft.com/en-us/azure/virtual-machines/windows/acu
    # Ratio 1 means each socket/core contains one vCPU
    #       2 means each socket/core contains two vCPUs
    case flavor_name.to_s
    when /_(D_v3|Ds_v3|E_v3|Es_v3|M)$/
      2
    when /_F\d+s_v2$/
      2
    when /_L\d+s_v2$/
      2
    else
      1
    end
  end
end
