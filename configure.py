"""Write local credentials interactively; never include them in the repository."""
from pathlib import Path
import getpass,secrets,os
os.umask(0o077)
p=Path.home()/'Library/Application Support/QuarkCinema'
p.mkdir(parents=True,exist_ok=True);p.chmod(0o700)
root=input('网盘中的影视根目录（例如 我的剧集）：').strip().strip('/')
if not root:raise SystemExit('目录不能为空。')
cookie=getpass.getpass('夸克 Cookie（输入不显示）：').strip()
if not cookie:raise SystemExit('Cookie 不能为空。')
values={'quark.cookie':cookie,'library-root.txt':root}
if not (p/'webdav.password').exists():values['webdav.password']=secrets.token_urlsafe(32)
for name,value in values.items():
 target=p/name;target.write_text(value);target.chmod(0o600)
print('已保存到本机私密配置目录。请勿上传此目录。')
