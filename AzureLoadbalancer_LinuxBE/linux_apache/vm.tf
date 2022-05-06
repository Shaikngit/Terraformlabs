#Create Azure ResourceGroup 
resource "azurerm_resource_group" "main" {
  name     = var.resourcegroup
  location = var.location
}

#Create Virtual Network for Backend VM  
resource "azurerm_virtual_network" "main" {
  name                = var.vnet_name
  address_space       = length(var.address_spaces) == 0 ? [var.address_space] : var.address_spaces
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  dns_servers = var.dns_servers
}

#Create Subnet to the Virtual Network 
resource "azurerm_subnet" "internal" {
  count               = length(var.subnet_names)
  name                 = var.subnet_names[count.index]
  resource_group_name  = azurerm_resource_group.main.name
  virtual_network_name = azurerm_virtual_network.main.name
  address_prefixes     = [var.subnet_prefixes[count.index]]
  enforce_private_link_endpoint_network_policies = lookup(var.subnet_enforce_private_link_endpoint_network_policies, var.subnet_names[count.index], false)
  service_endpoints    = lookup(var.subnet_service_endpoints, var.subnet_names[count.index], [])
}

#Create Public IP for the VMs 
resource "azurerm_public_ip" "apache_terraform_pip" {
  count = var.backendvmcount
  name                = "${var.prefix}-${count.index}-ip"
  location            = var.location
  resource_group_name = azurerm_resource_group.main.name
  allocation_method   = "Static"
  domain_name_label   = "${var.hostname}-${count.index}"
  sku = "Standard"
}

#Create Network Security Group 
resource "azurerm_network_security_group" "main_sg" {
  name                = "${var.prefix}-sg"
  location            = var.location
  resource_group_name = azurerm_resource_group.main.name

  security_rule {
    name                       = "HTTP"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "80"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }

  security_rule {
    name                       = "SSH"
    priority                   = 101
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "22"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }
}

#Create Network interface to the VMs
resource "azurerm_network_interface" "main" {
  count = var.backendvmcount
  name                = "${var.prefix}-${count.index}-nic"
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location

  ip_configuration {
    name                          = "internal"
    subnet_id                     = azurerm_subnet.internal[0].id 
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id = azurerm_public_ip.apache_terraform_pip[count.index].id
    
  }
}

#NSG Association 
resource "azurerm_subnet_network_security_group_association" "main" {
  count = length(var.subnet_names)
  subnet_id                 = azurerm_subnet.internal[count.index].id
  network_security_group_id = azurerm_network_security_group.main_sg.id
}


#Create Virtual machine Linux 
resource "azurerm_linux_virtual_machine" "main" {
  count = var.backendvmcount
  name                            = "${var.prefix}-${count.index}-vm"
  resource_group_name             = azurerm_resource_group.main.name
  location                        = azurerm_resource_group.main.location
  size                            = var.VMSize
  admin_username                  = "${var.username}"
  admin_password                  = "${var.password}"
  disable_password_authentication = true 
  network_interface_ids = [
    azurerm_network_interface.main[count.index].id,
  ]

  admin_ssh_key {
    username   = "${var.username}"
    public_key = file("~/.ssh/id_rsa.pub")
  }

  source_image_reference {
    publisher = var.image_publisher
    offer     = var.image_offer
    sku       = var.image_sku
    version   = var.image_version
  }

  os_disk {
    storage_account_type = "Standard_LRS"
    caching              = "ReadWrite"
  }
# This is to ensure SSH comes up before we run the local exec.
  provisioner "remote-exec" {
    inline = [
      "sudo apt-get update -y && sudo apt-get install apache2 -y && sudo systemctl start apache2",
      "echo '<h1><center>My first website using terraform provisioner</center></h1>' > index.html",
      "echo '<h1><center>Shaik Athahar Nawaz </center></h1>' >> index.html",
      "sudo mv index.html /var/www/html/"
    ]
    connection {
      type        = "ssh"
      host        = azurerm_public_ip.apache_terraform_pip[count.index].fqdn
      user        = var.username
      private_key = file("~/.ssh/id_rsa")
    }
  }
}