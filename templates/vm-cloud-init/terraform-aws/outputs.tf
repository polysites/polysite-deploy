output "public_ip" {
  description = "Point the A records of both domains here"
  value       = aws_eip.polysite.public_ip
}

output "next_steps" {
  value = "After 3 to 6 minutes: ssh ubuntu@${aws_eip.polysite.public_ip} sudo cat /root/polysite-setup.txt ; then open https://${var.admin_domain}/admin"
}
