# AutoHCK
AutoHCK is a tool for automating HCK/HLK testing.

## Dependencies
AutoHCK needs the following tools in order to run:
* [VirtHCK](https://github.com/daynix/VirtHCK/)
* [rtoolsHCK](https://github.com/HCK-CI/rtoolsHCK)

Beside that some additional ruby gems are required to run the AutoHCK:
* [fileutils](https://rubygems.org/gems/fileutils)
* [net-ping](https://rubygems.org/gems/net-ping)
* [filelock](https://rubygems.org/gems/filelock)
* [net-telnet](https://rubygems.org/gems/net-telnet)
* [ruby-progressbar](https://rubygems.org/gems/ruby-progressbar)

Install them automatically by running the command ``bundle install`` (you need bundler to do that ```gem install bundler```), or install them manually by doing the same for each one ```gem install gem-name```

## DHCP Configuration
In order to connect to the Studio machine in each HLK/HCK setup, we need to set up a DHCP server that will provide each studio with a unique IP address.  The server will assign the IP address according to the machine mac address with the following rule (replace XX with AutoHCK unique ID):

56:00:XX:00:XX:dd > 192.168.0.XX

There is more than one way to set up the DHCP Server, for now, we will be using openDHCP:
http://dhcpserver.sourceforge.net
The `opendhcpserverSetup.sh` script will download openDHCP, install it as a service and configure it with the required IP assignment rule.

The script will also create a new bridge named 'br1'. If this bridge is already used, you can change its name.
NOTE: you will need to change "WORLD_BR_NAME" in virtHCK config file to the bridge name.

## Installation
Follow instructions for complete setup installation: https://github.com/HCK-CI/HCK-CI-DOCS/blob/master/installing-hck-ci-from-scratch.txt

Keep in mind that AutoHCK can be used without Jenkins.

## Test VM installation
Follow instructions: https://github.com/HCK-CI/HLK-Setup-Scripts

## Configuration
A file named ```config.json``` will include the following configurations:
```
{
  "virthck_path": "/home/hck-ci/Prometheus/VirtHCK/",
  "qemu_img": "qemu-img",
  "qemu_bin": "qemu-kvm",
  "ip_segment": "192.168.0.", the ip range configured with opendhcp
  "dhcp_bridge": "br1", / the bridge configured for dhcp with opendhcp
  "toolshck_path": "/home/hck-ci/Prometheus/toolsHCK/toolsHCK.ps1",
  "studio_username": "Administrator",
  "studio_password": "Qum5net.",
  "repository": "Daynix/kvm-guest-drivers-windows" // github repository for updating checks status
  "github_credentials": {
    "login": "username",
    "password": "useraccestoken"
    }
}
```

## Device drivers list
All information about the drivers and their devices is listed in `devices.json`
```
  {
    "name": "Driver name", // exactly as showen in hck studio
    "id": "PCI\\VEN_1AF4&DEV_1004&SUBSYS_00081AF4&REV_00\\3&13C0B0C5&0&28",
    "short": "vioscsi",
    "device": {
      "type": "storage-scsi", // device information in qemu
      "name": "virtio-scsi-pci",
      "extra": ""
    },
    "inf": "vioscsi.inf",
    "support": false, // true if two clients needed for tests
    "platforms": [ // all operation systems we want to test on
      {
        "id": "26",
        "name": "Win10x64",
        "kit": "HLK1709",
        "c1_cpus": "4",
        "c1_memory": "4G"
        "world_net_device": "e1000e",
        "ctrl_net_device": "e1000e",
        "file_transfer_device": "e1000e"
      }
    ],
    "playlist": [ // OPTIONAL - list of test names we want to run (exact names)
      "[2 Machine] - MultiCast Address",
      "DF - InfVerif INF Verification"
    ]
  }
```
## Usage
```
-c, --commit <COMMIT-HASH>       Commit hash for updating github status
-d, --diff <DIFF-LIST-FILE>      The location of the driver
-t, --tag [PROJECT]-[OS][ARCH]   The driver name and architecture (required)
-p, --path [PATH-TO-DRIVER]      The location of the driver (required)
```
### Examples
```
ruby autoHCK.rb -t Balloon-Win10x86 -p /home/hck-ci/balloon/win10/x86
ruby autoHCK.rb -t NetKVM-Win10x64 -d /home/hck-ci/workspace -d diff_list_file.txt
ruby autoHCK.rb -t viostor-Win10x64 -d /home/hck-ci/viostor -d diff_list_file.txt -c ec3da560827922e5a82486cf19cd9c27e95455a9
```
