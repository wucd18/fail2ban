# Backtrance

[简体中文](./README.md) | English

A Cowrie-based SSH honeypot deployment tool with integrated logging and security features.

## Quick Start

### One-click Installation

```bash
bash <(curl -sL https://raw.githubusercontent.com/CurtisLu1/backtrace/main/install.sh)
```

### System Requirements

- Debian/Ubuntu System
- Root privileges
- Python 3.9+ (will automatically upgrade if system Python version is below 3.9)
  - Debian 10: via backports repository
  - Debian 11/12: via official repository
  - Ubuntu: via deadsnakes PPA

## Features

- Automatic Cowrie SSH honeypot deployment
- Integrated Fail2ban protection
- Automatic log cleanup (30 days retention by default)
- System log rotation
- Service auto-start
- SSH security configuration (optional):
  - Port configuration:
    - Keep existing configuration
    - Random generation (10000-65535)
    - Manual specification (1024-65535)
  - Authentication methods:
    - Keep existing configuration
    - Key-only authentication
    - Password + key authentication
  - Key management:
    - Keep existing keys
    - Import new public key
    - Auto-generate new key pair
- UFW firewall configuration (optional):
  - Auto-configure required ports (SSH and honeypot)
  - Smart rule management (automatic port change handling)
  - Detailed rule processing:
    - Auto add/remove rules
    - Rule conflict detection
    - Rule priority management

## Installation Process

1. Environment check:
   - System compatibility verification
   - Python environment detection
   - Required command check
2. Dependency installation:
   - fail2ban
   - Python virtualenv
   - Other required packages
3. Component configuration:
   - Cowrie honeypot (port 2222)
   - Fail2ban protection
   - Log cleanup (2 AM daily)
4. Security configuration:
   - SSH port configuration
   - Authentication method settings
   - Key management
   - Firewall rules

## Configuration Details

### Fail2ban Configuration
- Ban time: 24 hours (86400 seconds)
- Detection window: 5 minutes (300 seconds)
- Max retry: 3 times
- Monitored logs: auth.log and cowrie.log

### SSH Configuration Options
- Port selection:
  - Keep existing port
  - Random port (10000-65535)
  - Manual specification (1024-65535)
- Authentication methods:
  - Keep existing configuration
  - Key-only authentication
  - Password + key authentication
- Key options:
  - Keep existing keys
  - Import new public key
  - Generate new key pair (4096-bit RSA)

### Firewall Settings
- Auto-configure SSH port
- Auto-configure honeypot port (2222)
- Smart rule management
- Optional UFW enablement
- Detailed rule processing:
  - Auto add/remove rules
  - Rule conflict detection
  - Rule priority management

## Log Management

### Log Locations
- Cowrie logs: `/opt/cowrie/var/log/cowrie/`
- Fail2ban logs: `/var/log/fail2ban.log`
- System logs: `/var/log/`
- Cleanup logs: `/var/log/cleanup.log`

### Log Rotation
- Weekly rotation
- Keep 4 versions
- Automatic compression
- Auto-cleanup of logs older than 30 days

## Service Management

```bash
# Status check
systemctl status cowrie
systemctl status fail2ban
ufw status

# Log viewing
tail -f /opt/cowrie/var/log/cowrie/cowrie.log
journalctl -u cowrie -f
tail -f /var/log/fail2ban.log

# Service control
systemctl start|stop|restart cowrie
systemctl start|stop|restart fail2ban
```

## Security Recommendations

1. After installation:
   - Save the displayed SSH port number
   - Backup generated SSH keys (if any)
   - Keep current session before testing new configuration
2. Firewall configuration:
   - Ensure necessary ports are open
   - Recommend enabling UFW
   - Regular firewall rule checks
3. Regular maintenance:
   - Regular system log checks
   - Monitor honeypot logs
   - Timely system updates

## Uninstallation

```bash
# Stop services
systemctl stop cowrie
systemctl disable cowrie

# Remove files
rm -rf /opt/cowrie
rm /etc/systemd/system/cowrie.service

# Reload systemd
systemctl daemon-reload
```

## License

MIT License

Copyright (c) 2025

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

## Contributing

Welcome to contribute through:
- Submit Issues
- Submit Pull Requests
- Improve documentation
- Share usage experience

## Feedback

When encountering issues, please provide:
1. System version
2. Python version
3. Error messages
4. Relevant logs
