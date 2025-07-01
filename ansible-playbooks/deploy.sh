#!/bin/bash
# deploy.sh - Deployment script for three-server infrastructure

echo "Starting deployment of three-server infrastructure..."

# Check if Ansible is installed
if ! command -v ansible &> /dev/null; then
    echo "Installing Ansible..."
    sudo apt update
    sudo apt install -y ansible
fi

# Check if inventory file exists
if [ ! -f "inventory.ini" ]; then
    echo "Error: inventory.ini file not found!"
    echo "Please create inventory.ini with your server IPs"
    exit 1
fi

# Run the playbook
echo "Running Ansible playbook..."
ansible-playbook -i inventory.ini site.yml -v

# Check deployment status
if [ $? -eq 0 ]; then
    echo "Deployment completed successfully!"
    echo ""
    echo "Services should now be accessible at:"
    echo "- Grafana: http://GATEWAY_IP:3000 (admin/admin)"
    echo "- Prometheus: http://GATEWAY_IP:9090"
    echo "- Apache: http://GATEWAY_IP"
    echo "- Django: http://GATEWAY_IP:8000 (through application server)"
    echo ""
    echo "Next steps:"
    echo "1. Change default Grafana password"
    echo "2. Configure Grafana dashboards"
    echo "3. Update Django settings for production"
    echo "4. Set up SSL certificates"
    echo "5. Configure backup strategies"
else
    echo "Deployment failed! Check the error messages above."
    exit 1
fi