terraform {
  required_providers {
    coder = {
      source = "coder/coder"
    }
    openstack = {
      source  = "terraform-provider-openstack/openstack"
      version = "~> 3.0.0"
    }
  }
}

provider "openstack" {}

variable "workspace_network" {
  description = "name of network the vm will join"
  type = string
}

variable "featured_image" {
  description = "name of the most recent featured ubuntu image from jetstream2 team"
  type = string
}

variable "flavor_name" {
  description = "instance size"
  type = string
  default = "m3.quad"
}

# data "coder_parameter" "instance_type" {
#   name         = "instance_type"
#   display_name = "Instance Type"
#   description  = "What size instance for your workspace?"
#   default      = "m3.small"
#   option {
#     name  = "m3.small (2 CPUs, 6GB mem)"
#     value = "m3.small"
#   }
#   option {
#     name  = "m3.quad (4 CPUs, 15GB mem)"
#     value = "m3.quad"
#   }
#   option {
#     name  = "m3.medium (8 CPUs, 30GB mem)"
#     value = "m3.medium"
#   }
#   option {
#     name  = "m3.large (16 CPUs, 60GB mem)"
#     value = "m3.large"
#   }
#   option {
#     name  = "m3.xl (32 CPUs, 125GB mem)"
#     value = "m3.xl"
#   }
#   option {
#     name  = "g3.medium (8 CPUs, 30GB mem, GPU)"
#     value = "g3.medium"
#   }
#   option {
#     name  = "g3.large (16 CPUs, 60GB mem, GPU)"
#     value = "g3.large"
#   }
#   option {
#     name  = "g3.xl (32 CPUs, 125GB mem, GPU)"
#     value = "g3.xl"
#   }
# }

locals {
  linux_user = "coder"
  hostname = lower(data.coder_workspace.env.name)
}

data "coder_workspace" "env" {}
data "coder_workspace_owner" "me" {}

resource "coder_agent" "dev" {
  count          = data.coder_workspace.env.start_count
  arch           = "amd64"
  auth           = "token"
  os             = "linux"
  startup_script = <<-EOT
    set -e
    # install and start code-server
    curl -fsSL https://code-server.dev/install.sh | sh -s -- --method=standalone --prefix=/tmp/code-server --version 4.11.0
    
    # you can install extensions here
    # /tmp/code-server/bin/code-server --install-extension REditorSupport.r --force
    /tmp/code-server/bin/code-server --auth none --port 13337 >/tmp/code-server.log 2>&1 &
  EOT

  metadata {
    key          = "cpu"
    display_name = "CPU Usage"
    interval     = 5
    timeout      = 5
    script       = "coder stat cpu"
  }
  metadata {
    key          = "memory"
    display_name = "Memory Usage"
    interval     = 5
    timeout      = 5
    script       = "coder stat mem"
  }
  metadata {
    key          = "disk"
    display_name = "Disk Usage"
    interval     = 600 # every 10 minutes
    timeout      = 30  # df can take a while on large filesystems
    script       = "coder stat disk --path $HOME"
  }
}

resource "coder_app" "code-server" {
  count        = data.coder_workspace.env.start_count
  agent_id     = coder_agent.dev[0].id
  slug         = "code-server"
  display_name = "code-server"
  url          = "http://localhost:13337/?folder=/home/coder"
  icon         = "/icon/code.svg"
  subdomain    = false
  share        = "owner"

  healthcheck {
    url       = "http://localhost:13337/healthz"
    interval  = 3
    threshold = 10
  }
}

data "cloudinit_config" "user_data" {
  gzip          = false
  base64_encode = false
  boundary = "//"
  part {
    filename     = "cloud-config.yaml"
    content_type = "text/cloud-config"

    content = templatefile("${path.module}/cloud-init/cloud-config.yaml.tftpl", {
      hostname   = local.hostname
      linux_user = local.linux_user
    })
  }
  part {
    filename     = "userdata.sh"
    content_type = "text/x-shellscript"
    content = templatefile("${path.module}/cloud-init/userdata.sh.tftpl", {
      linux_user = local.linux_user
      init_script = try(coder_agent.dev[0].init_script, "")
    })
  }
}

resource "openstack_compute_instance_v2" "vm" {
  name ="coder-${data.coder_workspace_owner.me.name}-${data.coder_workspace.env.name}"
  image_name  = var.featured_image
  flavor_name = var.flavor_name
  security_groups   = ["default"]
  metadata = {
    coder_agent_token = try(coder_agent.dev[0].token, "")
  }
  user_data = data.cloudinit_config.user_data.rendered
  network {
    name = var.workspace_network
  }
  lifecycle {
    ignore_changes = [ user_data ]
  }
  # shelved_offloaded is the preferred "stopped" state, but we can't change to that state and also update metdata...
  # See this issue: 
  power_state = data.coder_workspace.env.transition == "start" ? "active" : "shutoff"
  tags = ["Name=coder-${data.coder_workspace_owner.me.name}-${data.coder_workspace.env.name}", "Coder_Provisioned=true"]  
}
