# see https://github.com/hashicorp/terraform
terraform {
  required_version = "1.9.6"
  required_providers {
    # see https://registry.terraform.io/providers/hashicorp/random
    random = {
      source  = "hashicorp/random"
      version = "3.6.3"
    }
    # see https://registry.terraform.io/providers/hashicorp/cloudinit
    # see https://github.com/hashicorp/terraform-provider-cloudinit
    cloudinit = {
      source  = "hashicorp/cloudinit"
      version = "2.3.5"
    }
    # see https://registry.terraform.io/providers/bpg/proxmox
    # see https://github.com/bpg/terraform-provider-proxmox
    proxmox = {
      source  = "bpg/proxmox"
      version = "0.65.0"
    }
  }
}

provider "proxmox" {
  ssh {
    node {
      name    = var.proxmox_pve_node_name
      address = var.proxmox_pve_node_address
    }
  }
}

variable "prefix" {
  type    = string
  default = "example-terraform-ubuntu"
}

variable "proxmox_pve_node_name" {
  type    = string
  default = "pve"
}

variable "proxmox_pve_node_address" {
  type = string
}

# see https://registry.terraform.io/providers/bpg/proxmox/0.65.0/docs/data-sources/virtual_environment_vms
data "proxmox_virtual_environment_vms" "ubuntu_templates" {
  tags = ["ubuntu-22.04", "template"]
}

# see https://registry.terraform.io/providers/bpg/proxmox/0.65.0/docs/data-sources/virtual_environment_vm
data "proxmox_virtual_environment_vm" "ubuntu_template" {
  node_name = data.proxmox_virtual_environment_vms.ubuntu_templates.vms[0].node_name
  vm_id     = data.proxmox_virtual_environment_vms.ubuntu_templates.vms[0].vm_id
}

# create a cloud-init cloud-config.
# NB cloud-init executes **all** these parts regardless of their result. they
#    should be idempotent.
# NB the output is saved at /var/log/cloud-init-output.log
# see journactl -u cloud-init
# see /run/cloud-init/*.log
# see https://cloudinit.readthedocs.io/en/latest/topics/examples.html#disk-setup
# see https://cloudinit.readthedocs.io/en/latest/topics/datasources/nocloud.html#datasource-nocloud
# see https://pve.proxmox.com/wiki/Cloud-Init_Support
# see https://registry.terraform.io/providers/hashicorp/cloudinit/latest/docs/data-sources/config
data "cloudinit_config" "example" {
  gzip          = false
  base64_encode = false
  part {
    content_type = "text/cloud-config"
    content      = <<-EOF
    #cloud-config
    fqdn: example.test
    manage_etc_hosts: true
    users:
      - name: vagrant
        passwd: '$6$rounds=4096$NQ.EmIrGxn$rTvGsI3WIsix9TjWaDfKrt9tm3aa7SX7pzB.PSjbwtLbsplk1HsVzIrZbXwQNce6wmeJXhCq9YFJHDx9bXFHH.'
        lock_passwd: false
        ssh_authorized_keys:
          - ${jsonencode(trimspace(file("~/.ssh/id_rsa.pub")))}
    disk_setup:
      /dev/sdb:
        table_type: gpt
        layout:
          - [100, 83]
        overwrite: false
    fs_setup:
      - label: data
        device: /dev/sdb1
        filesystem: ext4
        overwrite: false
    mounts:
      - [/dev/sdb1, /data, ext4, 'defaults,discard,nofail', '0', '2']
    runcmd:
      - echo 'Hello from cloud-config runcmd!'
      - sed -i '/vagrant insecure public key/d' /home/vagrant/.ssh/authorized_keys
    EOF
  }
}

# see https://registry.terraform.io/providers/bpg/proxmox/0.65.0/docs/resources/virtual_environment_file
resource "proxmox_virtual_environment_file" "example_ci_user_data" {
  content_type = "snippets"
  datastore_id = "local"
  node_name    = data.proxmox_virtual_environment_vms.ubuntu_templates.vms[0].node_name
  source_raw {
    file_name = "${var.prefix}-ci-user-data.txt"
    data      = data.cloudinit_config.example.rendered
  }
}

# see https://registry.terraform.io/providers/bpg/proxmox/0.65.0/docs/resources/virtual_environment_vm
resource "proxmox_virtual_environment_vm" "example" {
  name      = var.prefix
  node_name = "pve"
  tags      = sort(["ubuntu-22.04", "example", "terraform"])
  clone {
    vm_id = data.proxmox_virtual_environment_vm.ubuntu_template.vm_id
    full  = false
  }
  cpu {
    type  = "host"
    cores = 4
  }
  memory {
    dedicated = 4 * 1024
  }
  network_device {
    bridge = "vmbr0"
  }
  disk {
    interface   = "scsi0"
    file_format = "raw"
    iothread    = true
    ssd         = true
    discard     = "on"
    size        = 40
  }
  disk {
    interface   = "scsi1"
    file_format = "raw"
    iothread    = true
    ssd         = true
    discard     = "on"
    size        = 60
  }
  tpm_state {
    version = "v2.0"
  }
  agent {
    enabled = true
    trim    = true
  }
  initialization {
    ip_config {
      ipv4 {
        address = "dhcp"
      }
    }
    user_data_file_id = proxmox_virtual_environment_file.example_ci_user_data.id
  }
  provisioner "remote-exec" {
    inline = [
      <<-EOF
      cloud-init status --long --wait
      set -x
      id
      uname -a
      cat /etc/os-release
      echo "machine-id is $(cat /etc/machine-id)"
      hostname --fqdn
      cat /etc/hosts
      sudo sfdisk -l
      lsblk -x KNAME -o KNAME,SIZE,TRAN,SUBSYSTEMS,FSTYPE,UUID,LABEL,MODEL,SERIAL
      mount | grep ^/dev
      df -h
      EOF
      , <<-EOF
      sudo apt-get update
      sudo apt-get install -y tpm2-tools
      sudo systemd-cryptenroll --tpm2-device=list
      sudo tpm2 getekcertificate | openssl x509 -text -noout
      sudo tpm2 pcrread
      EOF
    ]
    connection {
      type     = "ssh"
      host     = self.ipv4_addresses[index(self.network_interface_names, "eth0")][0]
      user     = "vagrant"
      password = "vagrant"
    }
  }
}

output "ip" {
  value = proxmox_virtual_environment_vm.example.ipv4_addresses[index(proxmox_virtual_environment_vm.example.network_interface_names, "eth0")][0]
}
