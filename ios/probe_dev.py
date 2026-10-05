# -*- coding: utf-8 -*-
import asyncio, sys
from pymobiledevice3.lockdown import create_using_usbmux

async def main():
    try:
        d = await create_using_usbmux()
    except Exception as e:
        print('NO_DEVICE', type(e).__name__, e)
        return
    v = d.all_values
    print('DEVICE_OK', v.get('ProductType'), v.get('ProductVersion'), v.get('DeviceName'))
    print('UDID', v.get('UniqueDeviceID'))
    try:
        from pymobiledevice3.services.installation_proxy import InstallationProxyService
        apps = await InstallationProxyService(lockdown=d).get_apps(application_type='User')
        print('APP_COUNT', len(apps))
        for bid, info in sorted(apps.items()):
            name = info.get('CFBundleDisplayName') or info.get('CFBundleName') or ''
            print('APP', bid, '|', name, '|', info.get('CFBundleShortVersionString'))
    except Exception as e:
        print('APPS_FAIL', type(e).__name__, e)

asyncio.run(main())
