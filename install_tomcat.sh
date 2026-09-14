#!/bin/bash
# =============================================================
# Script d'automatisation - Installation & Configuration Tomcat
# Formation DevOps LINQINY - Module 1
# Version adaptée pour UBUNTU (apt / ufw, sans SELinux)
# =============================================================
# CE QUE FAIT CE SCRIPT (dans l'ordre) :
#   1. Vérifie que Java est déjà installé (prérequis, pas d'auto-install)
#   2. Télécharge et extrait Tomcat
#   3. Crée le compte système dédié (non-root)
#   4. Applique les permissions (pas de SELinux sur Ubuntu)
#   5. Crée et active le service systemd
#   6. Ouvre le port dans le firewall (ufw)
#   7. Configure l'accès au Manager (tomcat-users.xml)
#   8. (Optionnel) Déploie un fichier .war d'exemple
#
# PRÉREQUIS : Java (JDK) doit déjà être installé sur la machine
# avant de lancer ce script (ex. openjdk-21-jdk).
#
# UTILISATION :
#   1. Mets ce fichier et tomcat.conf dans le même dossier sur ta VM
#   2. Rends le script exécutable : chmod +x install_tomcat.sh
#   3. Lance-le en root :           sudo ./install_tomcat.sh
# =============================================================

# "set -e" = si une seule commande échoue, le script s'arrête tout de suite
# au lieu de continuer et de créer un bazar à moitié installé.
set -e

# --- Vérifier qu'on est bien lancé en root (sudo) ---
if [ "$EUID" -ne 0 ]; then
    echo "Erreur : ce script doit être lancé avec sudo (droits root nécessaires)."
    echo "Utilisation : sudo ./install_tomcat.sh"
    exit 1
fi

# =============================================================
# ÉTAPE 0 : Charger le fichier de configuration
# =============================================================
# On récupère le dossier où se trouve CE script, pour être sûr
# de trouver tomcat.conf même si on lance le script depuis ailleurs.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/tomcat.conf"

if [ ! -f "$CONFIG_FILE" ]; then
    echo "Erreur : fichier tomcat.conf introuvable dans $SCRIPT_DIR"
    echo "Il doit être dans le même dossier que ce script."
    exit 1
fi

# "source" charge les variables du fichier .conf dans ce script
# (comme un copier-coller de leur contenu ici)
source "$CONFIG_FILE"

echo "============================================================="
echo " Configuration chargée :"
echo "   Tomcat version : $TOMCAT_VERSION"
echo "   Utilisateur    : $SERVICE_USER"
echo "   Port           : $TOMCAT_PORT"
echo "============================================================="

# =============================================================
# ÉTAPE 1 : Vérifier que Java est déjà installé (prérequis)
# =============================================================
echo ""
echo ">>> [1/8] Vérification de Java..."

if ! command -v java &>/dev/null; then
    echo "Erreur : Java n'est pas installé sur cette machine."
    echo "Installe-le d'abord, par exemple : sudo apt-get install -y openjdk-21-jdk"
    exit 1
fi

# On détecte automatiquement le chemin d'installation de Java
# (utile pour JAVA_HOME plus tard, sans avoir à le deviner à la main)
JAVA_BIN_PATH=$(readlink -f "$(which java)")
JAVA_HOME_PATH=$(dirname "$(dirname "$JAVA_BIN_PATH")")
echo "    Java trouvé, JAVA_HOME détecté : $JAVA_HOME_PATH"

# =============================================================
# ÉTAPE 2 : Télécharger et extraire Tomcat
# =============================================================
echo ""
echo ">>> [2/8] Téléchargement de Tomcat $TOMCAT_VERSION..."

# Installer wget s'il n'existe pas déjà
command -v wget &>/dev/null || apt-get install -y wget

cd /tmp
TOMCAT_ARCHIVE="apache-tomcat-${TOMCAT_VERSION}.tar.gz"
TOMCAT_URL="https://dlcdn.apache.org/tomcat/tomcat-${TOMCAT_MAJOR}/v${TOMCAT_VERSION}/bin/${TOMCAT_ARCHIVE}"

wget -q "$TOMCAT_URL" -O "$TOMCAT_ARCHIVE"
tar xzf "$TOMCAT_ARCHIVE"

echo ">>> Installation dans $INSTALL_DIR..."
# On supprime une éventuelle ancienne installation avant de remettre la nouvelle
rm -rf "$INSTALL_DIR"
mv "apache-tomcat-${TOMCAT_VERSION}" "$INSTALL_DIR"
rm -f "$TOMCAT_ARCHIVE"

# =============================================================
# ÉTAPE 3 : Créer le compte applicatif non-root
# =============================================================
echo ""
echo ">>> [3/8] Vérification du compte $SERVICE_USER..."

# "id" renvoie une erreur si l'utilisateur n'existe pas -> on teste ça
if ! id "$SERVICE_USER" &>/dev/null; then
    useradd -r -m -U -d "$INSTALL_DIR" -s /bin/false "$SERVICE_USER"
    echo "    Compte $SERVICE_USER créé."
else
    echo "    Compte $SERVICE_USER existe déjà, on le réutilise (pas de recréation)."
fi

# =============================================================
# ÉTAPE 4 : Permissions
# =============================================================
# Pas de SELinux sur Ubuntu (il utilise AppArmor, désactivé par défaut
# pour un usage applicatif classique comme Tomcat) : seules les
# permissions Unix standards sont nécessaires ici.
echo ""
echo ">>> [4/8] Application des permissions..."

chown -R "$SERVICE_USER:$SERVICE_GROUP" "$INSTALL_DIR"
chmod +x "$INSTALL_DIR"/bin/*.sh

# =============================================================
# ÉTAPE 5 : Créer et activer le service systemd
# =============================================================
echo ""
echo ">>> [5/8] Création du service systemd..."

# "cat > fichier << EOF ... EOF" écrit tout le bloc de texte dans le fichier
# d'un coup, sans risque de caractères parasites (contrairement à nano+copier-coller)
cat > /etc/systemd/system/tomcat.service << EOF
[Unit]
Description=Apache Tomcat
After=network.target

[Service]
Type=forking
User=$SERVICE_USER
Group=$SERVICE_GROUP
Environment=JAVA_HOME=$JAVA_HOME_PATH
Environment=CATALINA_HOME=$INSTALL_DIR
ExecStart=$INSTALL_DIR/bin/startup.sh
ExecStop=$INSTALL_DIR/bin/shutdown.sh
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now tomcat

echo "    Service tomcat créé et démarré."

# =============================================================
# ÉTAPE 6 : Ouvrir le port dans le firewall (ufw)
# =============================================================
echo ""
echo ">>> [6/8] Ouverture du port $TOMCAT_PORT dans le firewall..."

if ! command -v ufw &>/dev/null; then
    echo "    ufw introuvable, installation..."
    apt-get install -y ufw
fi

# On s'assure de ne pas se couper l'accès SSH si ufw n'était pas encore actif
ufw allow OpenSSH >/dev/null 2>&1 || true
ufw allow "${TOMCAT_PORT}/tcp"
yes | ufw enable
echo "    Port $TOMCAT_PORT/tcp ouvert."

# =============================================================
# ÉTAPE 7 : Configurer l'accès Manager (tomcat-users.xml)
# =============================================================
echo ""
echo ">>> [7/8] Configuration de l'accès Manager..."

USERS_FILE="$INSTALL_DIR/conf/tomcat-users.xml"

# "sed" cherche la ligne </tomcat-users> et insère notre nouvel
# utilisateur juste avant, seulement s'il n'existe pas déjà
# (pour pouvoir relancer le script sans dupliquer la ligne).
if ! grep -q "username=\"$MANAGER_USER\"" "$USERS_FILE"; then
    sed -i "s#</tomcat-users>#  <user username=\"$MANAGER_USER\" password=\"$MANAGER_PASSWORD\" roles=\"manager-gui,admin-gui\"/>\n</tomcat-users>#" "$USERS_FILE"
    echo "    Utilisateur Manager '$MANAGER_USER' ajouté."
else
    echo "    Utilisateur Manager '$MANAGER_USER' déjà présent, rien à faire."
fi

systemctl restart tomcat

# =============================================================
# ÉTAPE 8 (optionnelle) : Déployer un fichier .war
# =============================================================

echo ">>> [8/8] Déploiement de l'application..."

if [ -n "$WAR_FILE" ]; then

    if [ -f "$WAR_FILE" ]; then

        echo "WAR trouvé : $WAR_FILE"

        echo "Copie du WAR vers $INSTALL_DIR/webapps/..."

        cp "$WAR_FILE" "$INSTALL_DIR/webapps/"

        chown "$SERVICE_USER:$SERVICE_GROUP" \
            "$INSTALL_DIR/webapps/$(basename "$WAR_FILE")"

        echo "WAR déployé avec succès !"

    else

        echo "ERREUR : WAR introuvable : $WAR_FILE"
        exit 1
    fi

else

    echo "WAR_FILE vide : étape ignorée."

fi

# =============================================================
# RÉCAPITULATIF FINAL
# =============================================================
IP_VM=$(hostname -I | awk '{print $1}')

echo ""
echo "============================================================="
echo " Installation terminée avec succès !"
echo ""
echo " Tomcat      : http://$IP_VM:$TOMCAT_PORT"
echo " Manager     : http://$IP_VM:$TOMCAT_PORT/manager (user: $MANAGER_USER)"
echo " Statut      : systemctl status tomcat"
echo "============================================================="
