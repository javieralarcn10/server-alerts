# server-alerts

Alertas por Telegram para tus servidores Linux (Debian/Ubuntu):

- 🔐 **Login SSH**: usuario, IP, ubicación aproximada y hora.
- ⚠️ **Disco / RAM / CPU ≥ 80%**: se comprueba cada 5 min. Avisa como mucho una vez por hora por métrica y te dice cuándo vuelve a la normalidad.

Solo Bash + `curl` + `python3` (el instalador los pone). Sin agentes, sin dependencias externas, sin cuentas en terceros.

**Requisitos**
- Servidor Linux con **systemd** (probado en Debian/Ubuntu; con `apt` instala las dependencias solo).
- Acceso SSH con `root` o un usuario con `sudo`.
- En tu ordenador (para `deploy.sh`): `bash`, `ssh` y `tar` (macOS y Linux ya los traen).
- Un bot de Telegram (gratis, 1 minuto: ver abajo).

---

## 1. Una sola vez: datos de Telegram

Clona el repo y crea tu `config.env` a partir de la plantilla:

```bash
git clone https://github.com/javieralarcn10/server-alerts.git
cd server-alerts
cp config.env.example config.env
```

Abre `config.env` y pon el token del bot y tu chat_id. Estos datos sirven para **todos** tus servidores.

```bash
TELEGRAM_BOT_TOKEN="123456789:AAxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"
TELEGRAM_CHAT_ID="123456789"
ALERT_TZ="Europe/Madrid"   # tu zona horaria
```

> `config.env` está en `.gitignore`: tu token nunca se sube a git. Si no lo creas, el instalador te pedirá token y chat_id en cada servidor.

<details>
<summary>¿No tienes bot o chat_id todavía?</summary>

1. En Telegram, habla con [@BotFather](https://t.me/BotFather) → `/newbot` → te da el **token**.
2. Abre tu bot nuevo y pulsa **Start**.
3. Abre en el navegador `https://api.telegram.org/bot<TOKEN>/getUpdates` y busca `"chat":{"id":123456789`. Ese número es el **chat_id**.
4. ¿Quieres las alertas en un grupo? Añade el bot al grupo, escribe algo y repite el paso 3: el chat_id del grupo empieza por `-100`.
</details>

---

## 2. Instalar en un servidor

Desde tu ordenador, dentro de esta carpeta:

```bash
./deploy.sh usuario@IP_DEL_SERVIDOR      # p. ej. root@203.0.113.10 o ubuntu@203.0.113.10
```

Te pide el **nombre del servidor** (el que verás en las alertas) y, si hace falta, la contraseña de sudo. Ya está.

Para varios servidores de una vez (te pregunta el nombre de cada uno):

```bash
./deploy.sh root@203.0.113.10 ubuntu@203.0.113.11 ubuntu@203.0.113.12
```

El instalador hace solo: `apt update`, instala `curl` y `python3`, configura el aviso SSH (PAM), activa el timer de recursos y te manda un mensaje de prueba.

<details>
<summary>Alternativa: instalar a mano desde el servidor</summary>

```bash
scp -r server-alerts usuario@IP:/tmp/
ssh usuario@IP
sudo bash /tmp/server-alerts/install.sh
```

Sin preguntas: `sudo bash install.sh --name "Web-Produccion"`
</details>

Volver a ejecutar el instalador es seguro: sirve para **actualizar** o **cambiar el nombre**.

---

## 3. Probar

```bash
sudo /opt/server-alerts/bin/telegram.sh "hola"            # mensaje de prueba
sudo PAM_TYPE=open_session PAM_USER=$USER PAM_RHOST=8.8.8.8 /opt/server-alerts/bin/ssh-notify.sh
sudo /opt/server-alerts/bin/resource-check.sh             # comprobar recursos ya
sudo tail -f /var/log/server-alerts.log                   # ver log
```

---

## 4. Cambiar ajustes de un servidor

```bash
sudo nano /opt/server-alerts/config.env
```

Ahí están el nombre, los umbrales (`THRESHOLD_DISK`, `THRESHOLD_RAM`, `THRESHOLD_CPU`), el cooldown y `IGNORE_IPS` / `IGNORE_USERS` (por ejemplo, para no recibir avisos de las conexiones automáticas de tu panel o de tu CI). Los cambios se aplican en la siguiente alerta.

```bash
THRESHOLD_DISK=90
IGNORE_IPS="203.0.113.50 198.51.100.7"
IGNORE_USERS="deployer backup"
```

---

## 5. Desinstalar

```bash
sudo /opt/server-alerts/uninstall.sh           # conserva el log
sudo /opt/server-alerts/uninstall.sh --purge   # borra también el log
```

---

## Detalles técnicos

| Qué | Cómo |
|-----|------|
| Login SSH | `pam_exec` en `/etc/pam.d/sshd` (con backup). Es `optional` y se ejecuta en segundo plano: nunca bloquea ni retrasa el login. Si no existe PAM, usa `/var/log/auth.log`. |
| Disco | Peor `%` de `df -P` (sin tmpfs, overlay, squashfs…) |
| RAM | `(MemTotal - MemAvailable) / MemTotal` |
| CPU | loadavg de 5 min / núcleos |
| Geo | `ipapi.co` (HTTPS, sin clave, 3 s de timeout). IPs privadas no se consultan. |
| Persistencia | Timer systemd `enabled`: sigue funcionando tras reiniciar. |

**Seguridad:** el token vive en `/opt/server-alerts/config.env` (root, chmod 600) y no aparece en `ps` al enviar. `config.env` está en `.gitignore`; si haces un fork, no lo quites de ahí.

**Privacidad:** en cada login SSH desde una IP pública, esa IP se envía a [ipapi.co](https://ipapi.co) para obtener ciudad y país (plan gratuito con límite diario; si falla, la alerta llega igual con "Ubicación: desconocida"). Las alertas pasan por los servidores de Telegram.

```
server-alerts/
  config.env.example ← plantilla: cópiala a config.env
  config.env        ← tu token y chat_id (NO se sube a git)
  deploy.sh         ← instalar desde tu ordenador
  install.sh / uninstall.sh
  bin/              common.sh, telegram.sh, ssh-notify.sh, resource-check.sh, authlog-notify.sh
  systemd/          timer + service de recursos
  extras/           fallback auth.log
```

---

## Licencia

MIT — ver [LICENSE](LICENSE).
