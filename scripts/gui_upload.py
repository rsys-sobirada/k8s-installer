#!/usr/bin/env python3
"""
gui_upload.py - AMF uploader with Import overwrite verification

Flow:
  - Login
  - Configure -> AMF -> amf
  - Choose File -> Import
  - Verify import updated GUI with selected config
  - Apply -> Ok
  - Capture success/fail popup and verify config in GUI
"""

import os
import re
import time
import json
import traceback
from selenium import webdriver
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

driver = webdriver.Firefox(options=options)
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

# ---------------- Utilities ----------------
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

# ---------------- Navigation helpers ----------------
def open_configure_menu():
    step.snap("S_BEFORE_click_configure", html=True)
    el = _first_visible(driver.find_elements(By.XPATH, "//a[contains(translate(.,'ABCDEFGHIJKLMNOPQRSTUVWXYZ','abcdefghijklmnopqrstuvwxyz'),'configure')]"))
    if not el:
        step.snap("S_ERR_click_configure", html=True)
        raise Exception("Configure not found")
    driver.execute_script("arguments[0].click();", el)
    time.sleep(MED_SLEEP)
    step.snap("S_CLICKED_configure", html=True)

def open_nf_menu(name):
    step.snap(f"S_BEFORE_nf_{name}", html=True)
    el = _first_visible(driver.find_elements(By.XPATH, f"//a[contains(translate(.,'ABCDEFGHIJKLMNOPQRSTUVWXYZ','abcdefghijklmnopqrstuvwxyz'),'{name.lower()}')]"))
    if not el:
        step.snap(f"S_ERR_nf_{name}", html=True)
        raise Exception(f"{name} not found")
    driver.execute_script("arguments[0].click();", el)
    time.sleep(MED_SLEEP)
    step.snap(f"S_CLICKED_nf_{name}", html=True)

def click_amf_subentry():
    step.snap("S_BEFORE_click_amf", html=True)
    el = _first_visible(driver.find_elements(By.XPATH, "//*[normalize-space(text())='amf']"))
    if not el:
        step.snap("S_ERR_click_amf", html=True)
        raise Exception("amf subentry not found")
    driver.execute_script("arguments[0].click();", el)
    time.sleep(MED_SLEEP)
    step.snap("S_CLICKED_amf", html=True)

# ---------------- Import helpers ----------------
def upload_config_file(file_path):
    step.snap("S_BEFORE_upload", html=True)

    # ORIGINAL logic fix: always use absolute path
    abs_path = os.path.abspath(file_path)
    if not os.path.exists(abs_path):
        step.snap("S_ERR_file_missing", html=True)
        raise FileNotFoundError(f"Config file not found: {abs_path}")

    print(f"[DEBUG] Uploading config file: {abs_path}")

    inp = driver.find_element(By.XPATH, "//input[@type='file']")
    driver.execute_script("arguments[0].style.display='block'; arguments[0].style.visibility='visible';", inp)
    inp.send_keys(abs_path)  # <<< original safe logic
    driver.execute_script("arguments[0].dispatchEvent(new Event('change',{bubbles:true}));", inp)

    time.sleep(SHORT_SLEEP)
    step.snap("S_AFTER_upload", html=True)


def click_import():
    step.snap("S_BEFORE_import", html=True)
    el = _first_visible(driver.find_elements(By.XPATH, "//*[contains(translate(.,'ABCDEFGHIJKLMNOPQRSTUVWXYZ','abcdefghijklmnopqrstuvwxyz'),'import')]"))
    if not el:
        step.snap("S_ERR_import_not_found", html=True)
        raise Exception("Import button not found")
    driver.execute_script("arguments[0].click();", el)
    time.sleep(MED_SLEEP)
    step.snap("S_AFTER_import", html=True)

def wait_for_import_effect(json_file, timeout=10):
    """Verify import updated the GUI with config from the JSON file."""
    try:
        with open(json_file, "r", encoding="utf-8") as f:
            data = f.read(300)
    except Exception:
        return False

    # take some key words from JSON
    candidates = []
    try:
        j = json.loads(data)
        if isinstance(j, dict):
            for k in list(j.keys())[:3]:
                candidates.append(str(k))
    except Exception:
        # fallback raw
        candidates = data.split()

    end = time.time() + timeout
    while time.time() < end:
        src = driver.page_source.lower()
        if any(c.lower() in src for c in candidates if len(c) > 3):
            step.snap("S_IMPORT_effect_detected", html=True)
            return True
        time.sleep(0.5)

    step.snap("S_IMPORT_effect_missing", html=True)
    raise Exception("Import did not update GUI")

# ---------------- Apply helpers ----------------
def apply_and_confirm():
    step.snap("S_BEFORE_apply", html=True)
    el = _first_visible(driver.find_elements(By.XPATH, "//*[contains(translate(.,'ABCDEFGHIJKLMNOPQRSTUVWXYZ','abcdefghijklmnopqrstuvwxyz'),'apply')]"))
    if not el:
        step.snap("S_ERR_apply_not_found", html=True)
        raise Exception("Apply not found")
    driver.execute_script("arguments[0].click();", el)
    time.sleep(MED_SLEEP)
    step.snap("S_CLICKED_apply", html=True)

    # confirm OK
    ok = _first_visible(driver.find_elements(By.XPATH, "//button[contains(translate(.,'ABCDEFGHIJKLMNOPQRSTUVWXYZ','abcdefghijklmnopqrstuvwxyz'),'ok')]"))
    if ok:
        driver.execute_script("arguments[0].click();", ok)
        step.snap("S_CLICKED_ok", html=True)
    else:
        handle_native_alerts(timeout=3, accept=True)
        step.snap("S_OK_alert", html=True)

# ---------------- Main flow ----------------
def main():
    try:
        print("Starting GUI upload run")
        driver.get(URL)
        wait_document_ready(25)
        step.snap("S_LOGIN_open", html=True)

        # login
        u = driver.find_element(By.XPATH, "//input[@type='text' or @type='email']")
        p = driver.find_element(By.XPATH, "//input[@type='password']")
        u.send_keys(USERNAME)
        p.send_keys(PASSWORD)
        p.send_keys(Keys.RETURN)
        time.sleep(MED_SLEEP)
        step.snap("S_AFTER_login", html=True)

        # navigate
        open_configure_menu()
        open_nf_menu("AMF")
        click_amf_subentry()

        # process configs
        for fname in sorted(os.listdir(CONFIG_DIR)):
            if not fname.lower().endswith("_amf.json"):
                continue
            fpath = os.path.join(CONFIG_DIR, fname)
            print("Processing:", fpath)
            upload_config_file(fpath)
            click_import()
            wait_for_import_effect(fpath, timeout=12)
            apply_and_confirm()
            step.snap("S_DONE_apply", html=True)

        print("All AMF uploads processed.")
    except Exception as e:
        print("Error:", e)
        traceback.print_exc()
        step.snap("S_ERR", html=True)
        raise
    finally:
        driver.quit()

if __name__ == "__main__":
    main()
