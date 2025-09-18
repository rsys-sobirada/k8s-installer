#!/usr/bin/env python3
"""
gui_upload.py - AMF uploader with robust Import + Apply + confirmation handling,
plus network capture using selenium-wire.
"""

import os
import re
import time
import json
import traceback
from seleniumwire import webdriver  # NEW: selenium-wire instead of selenium.webdriver
from selenium.webdriver.firefox.options import Options
from selenium.webdriver.common.by import By
from selenium.webdriver.common.keys import Keys
from selenium.webdriver.common.action_chains import ActionChains
from selenium.webdriver.support.ui import WebDriverWait
from selenium.webdriver.support import expected_conditions as EC
from selenium.common.exceptions import TimeoutException

# ---------------- Configuration ----------------
URL = os.environ.get("EMS_URL", "https://172.27.28.193.nip.io/ems/login")
USERNAME = os.environ.get("EMS_USER", "root")
PASSWORD = os.environ.get("EMS_PASS", "root123")
CONFIG_DIR = os.environ.get("CONFIG_DIR", "config_files")
DEBUG_DIR = os.environ.get("DEBUG_DIR", "debug_screenshots")
os.makedirs(DEBUG_DIR, exist_ok=True)

HEADLESS = os.environ.get("HEADLESS", "1") != "0"
FAST_MODE = os.environ.get("FAST_MODE", "0") == "1"

SHORT_SLEEP = 0.2 if FAST_MODE else 0.6
MED_SLEEP   = 0.6 if FAST_MODE else 1.2
LONG_SLEEP  = 1.2 if FAST_MODE else 3.0

# ---------------- WebDriver Setup ----------------
options = Options()
if HEADLESS:
    options.add_argument("--headless")
options.accept_insecure_certs = True
options.add_argument("--no-sandbox")
options.add_argument("--disable-dev-shm-usage")

# Use selenium-wire Firefox driver
sw_options = {'verify_ssl': False}
driver = webdriver.Firefox(options=options, seleniumwire_options=sw_options)
try:
    driver.set_window_size(1400, 1100)
except Exception:
    pass

# ---------------- Debug capture ----------------
class StepCapture:
    def __init__(self, base_dir):
        self.base_dir = base_dir
        self.counter = 0
        os.makedirs(base_dir, exist_ok=True)

    def _clean(self, s):
        return re.sub(r"[^0-9A-Za-z._-]+", "_", str(s))[:80] or "step"

    def snap(self, label, html=False):
        self.counter += 1
        ts = int(time.time())
        name = f"{ts}_{self.counter:03d}_{self._clean(label)}"
        png = os.path.join(self.base_dir, name + ".png")
        try:
            driver.save_screenshot(png)
            print(f"[CAPTURE] {png}")
        except Exception as e:
            print("screenshot failed:", e)
        if html:
            try:
                htm = os.path.join(self.base_dir, name + ".html")
                with open(htm, "w", encoding="utf-8") as fh:
                    fh.write(driver.page_source)
                print(f"[CAPTURE] {htm}")
            except Exception as e:
                print("save page-source failed:", e)

step = StepCapture(DEBUG_DIR)

# ---------------- Utility helpers ----------------
def wait_document_ready(timeout=20):
    end = time.time() + timeout
    while time.time() < end:
        try:
            if driver.execute_script("return document.readyState") == "complete":
                return True
        except Exception:
            pass
        time.sleep(0.2)
    return False

def _first_visible(elements):
    for e in elements:
        try:
            if e.is_displayed():
                return e
        except Exception:
            continue
    return None

def handle_native_alerts(timeout=6, accept=True):
    try:
        WebDriverWait(driver, timeout).until(EC.alert_is_present())
        alert = driver.switch_to.alert
        txt = alert.text or ""
        print("Native alert:", txt)
        if accept:
            alert.accept()
        else:
            alert.dismiss()
        time.sleep(SHORT_SLEEP)
        return txt
    except TimeoutException:
        return ""
    except Exception as e:
        print("alert handling error:", e)
        return ""

def wait_for_no_overlay(wait=12):
    overlay_xpaths = [
        "//*[contains(@class,'overlay') or contains(@class,'backdrop') or contains(@class,'modal-backdrop') or contains(@class,'cdk-overlay-backdrop')]",
        "//*[contains(@class,'spinner') or contains(@class,'loading') or contains(@class,'progress')]"
    ]
    deadline = time.time() + wait
    while time.time() < deadline:
        visible = False
        for xp in overlay_xpaths:
            try:
                for e in driver.find_elements(By.XPATH, xp):
                    try:
                        if e.is_displayed():
                            visible = True
                            break
                    except Exception:
                        pass
                if visible:
                    break
            except Exception:
                pass
        if not visible:
            return True
        time.sleep(0.25)
    return False

# ---------------- Navigation helpers (same as before) ----------------
# (keep open_configure_menu, open_nf_menu, click_amf_subentry, upload_config_file,
#  click_import, apply_and_confirm, click_fetch, verify_config_applied,
#  capture_result_toast — unchanged from last working version)

# ... [Keep all the functions from previous working script here unchanged] ...

# ---------------- Network capture ----------------
def save_apply_requests(tag="apply_log"):
    """
    Scan selenium-wire captured requests for 'import' or 'apply',
    save details to DEBUG_DIR/tag_*.txt
    """
    ts = int(time.time())
    out_file = os.path.join(DEBUG_DIR, f"{ts}_{tag}.txt")
    with open(out_file, "w", encoding="utf-8") as fh:
        for req in driver.requests:
            if not req.response:
                continue
            url = req.url.lower()
            if "apply" in url or "import" in url:
                fh.write(f"\n=== REQUEST {req.url} ===\n")
                fh.write(f"Method: {req.method}\n")
                try:
                    fh.write(f"Status: {req.response.status_code}\n")
                except Exception:
                    fh.write("Status: (unknown)\n")
                fh.write("Request headers:\n")
                try:
                    for k, v in req.headers.items():
                        fh.write(f"  {k}: {v}\n")
                except Exception:
                    pass
                fh.write("\nResponse headers:\n")
                try:
                    for k, v in req.response.headers.items():
                        fh.write(f"  {k}: {v}\n")
                except Exception:
                    pass
                fh.write("\nResponse body:\n")
                try:
                    body = req.response.body.decode(errors="ignore")
                    fh.write(body[:5000])  # truncate for safety
                except Exception:
                    fh.write("(body decode failed)\n")
                fh.write("\n-----------------------------\n")
    print(f"[NETWORK_CAPTURE] saved {out_file}")

# ---------------- Main flow ----------------
def main():
    try:
        print("Starting GUI upload run")
        driver.get(URL)
        step.snap("S_LOGIN_page_open", html=True)
        wait_document_ready(25)
        time.sleep(MED_SLEEP)

        # login
        u = driver.find_element(By.XPATH, "//input[@type='text' or @type='email']")
        p = driver.find_element(By.XPATH, "//input[@type='password']")
        u.clear(); u.send_keys(USERNAME)
        p.clear(); p.send_keys(PASSWORD)
        p.send_keys(Keys.RETURN)
        time.sleep(MED_SLEEP)
        step.snap("S_AFTER_login", html=True)

        # navigate
        open_configure_menu()
        open_nf_menu("AMF")
        click_amf_subentry()
        step.snap("S_AFTER_amf_ready", html=True)

        # process files
        if not os.path.isdir(CONFIG_DIR):
            raise Exception(f"CONFIG_DIR '{CONFIG_DIR}' not found")
        for fname in sorted(os.listdir(CONFIG_DIR)):
            if not fname.lower().endswith("_amf.json"):
                continue
            fpath = os.path.abspath(os.path.join(CONFIG_DIR, fname))
            print("Processing:", fpath)
            step.snap(f"S_START_upload_{fname}", html=True)

            upload_config_file(fpath)
            click_import()
            apply_and_confirm()
            step.snap("S_AFTER_apply_and_ok", html=True)

            # save network activity for this run
            save_apply_requests(tag=f"apply_{fname}")

            # capture result toast
            status, msg, _, _ = capture_result_toast(timeout=8)
            print("Toast:", status, msg)

            # optional verification
            if status == "success":
                verify_config_applied(fpath, timeout=8)

        print("All AMF uploads processed.")
    except Exception as e:
        print("Main flow error:", e)
        traceback.print_exc()
        step.snap("S_ERR_main_exception", html=True)
        raise
    finally:
        try:
            driver.quit()
        except Exception:
            pass

if __name__ == "__main__":
    main()
