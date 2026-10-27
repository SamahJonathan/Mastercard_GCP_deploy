# Configuración de este despliegue (se versiona: no lleva secretos).
# El secreto OAuth del dashboard está en secrets.auto.tfvars, fuera de git.
project_id          = "paylake-gcp-fdec"
region              = "southamerica-east1"
github_repo         = "SamahJonathan/Mastercard_GCP_deploy"
alert_email         = "jona.samah@gmail.com"
admin_members       = ["user:jona.samah@gmail.com"]
consultant_members  = ["user:jonathansamahleiva@gmail.com"]
iap_oauth_client_id = "489794655559-ib61k98hfpdsnl2lmsvfd3ei55njiccu.apps.googleusercontent.com"
