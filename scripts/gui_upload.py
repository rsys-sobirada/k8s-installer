import os
import re
import asyncio
from playwright.async_api import async_playwright

async def automate_amf_upload():
    config_dir = "config_files"
    url = "https://172.27.28.193.nip.io/ems/login"
    username = "root"
    password = "root123"

    amf_file = None
    for file in os.listdir(config_dir):
        if re.search(r"(amf-function-.*_amf\\.json|.*_amf\\.json|amf\\.json)$", file):
            amf_file = os.path.abspath(os.path.join(config_dir, file))
            break

    if not amf_file:
        raise FileNotFoundError("No AMF config file found in config_files directory.")

    async with async_playwright() as p:
        browser = await p.chromium.launch(headless=True)
        context = await browser.new_context()
        page = await context.new_page()

        await page.goto(url)
        await page.fill("input[placeholder='Enter your username']", username)
        await page.fill("input[placeholder='Enter your password']", password)
        await page.click("button:has-text('Login')")
        await page.wait_for_timeout(3000)

        await page.click("text=Configure")
        await page.click("text=AMF")
        await page.click("text=Add")
        await page.click("text=amf")
        await page.set_input_files("input[type='file']", amf_file)
        await page.click("button:has-text('Import')")
        await page.click("button:has-text('Apply')")
        await page.click("button:has-text('OK')")

        await browser.close()

if __name__ == "__main__":
    asyncio.run(automate_amf_upload())
