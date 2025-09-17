#!/usr/bin/env python3
"""
gui_upload.py - AMF uploader with robust Import + Apply + confirmation handling.

Flow:
  - Login
  - Configure -> AMF -> amf
  - Choose File -> Import
  - Apply (scroll if needed) -> Confirmation popup -> Ok
  - Repeat for files in config_files

Screenshots + HTML saved to debug_screenshots/ for Jenkins artifacts.
"""

import os
import re
import time
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

# ---------------- Navigation helpers ----------------
def open_configure_menu():
    step.snap("S_BEFORE_click_configure", html=True)
    wait_for_no_overlay(wait=8)
    xps = [
        "//nav//a//*[contains(translate(normalize-space(.),'ABCDEFGHIJKLMNOPQRSTUVWXYZ','abcdefghijklmnopqrstuvwxyz'),'configure')]",
        "//a[contains(translate(normalize-space(.),'ABCDEFGHIJKLMNOPQRSTUVWXYZ','abcdefghijklmnopqrstuvwxyz'),'configure')]",
    ]
    for xp in xps:
        try:
            el = _first_visible(driver.find_elements(By.XPATH, xp))
            if el:
                try:
                    el.click()
                except Exception:
                    driver.execute_script("arguments[0].click();", el)
                time.sleep(MED_SLEEP)
                step.snap("S_CLICKED_configure", html=True)
                return True
        except Exception:
            continue
    step.snap("S_ERR_click_configure", html=True)
    raise Exception("open_configure_menu: Configure not found")

def open_nf_menu(name):
    step.snap(f"S_BEFORE_open_nf_{name}", html=True)
    wait_for_no_overlay(wait=8)
    t = name.lower()
    xps = [
        f"//nav//a//*[contains(translate(normalize-space(.),'ABCDEFGHIJKLMNOPQRSTUVWXYZ','abcdefghijklmnopqrstuvwxyz'),'{t}')]",
        f"//a[contains(translate(normalize-space(.),'ABCDEFGHIJKLMNOPQRSTUVWXYZ','abcdefghijklmnopqrstuvwxyz'),'{t}')]",
    ]
    for xp in xps:
        try:
            el = _first_visible(driver.find_elements(By.XPATH, xp))
            if el:
                try:
                    el.click()
                except Exception:
                    driver.execute_script("arguments[0].click();", el)
                time.sleep(MED_SLEEP)
                step.snap(f"S_CLICKED_nf_{name}", html=True)
                return True
        except Exception:
            continue
    step.snap(f"S_ERR_click_nf_{name}", html=True)
    raise Exception(f"open_nf_menu: {name} not found")

def click_amf_subentry():
    step.snap("S_BEFORE_click_amf_subentry", html=True)
    wait_for_no_overlay(wait=8)
    el = None
    try:
        el = _first_visible(driver.find_elements(By.XPATH, "//*[translate(normalize-space(.),'ABCDEFGHIJKLMNOPQRSTUVWXYZ','abcdefghijklmnopqrstuvwxyz')='amf']"))
    except Exception:
        pass
    if not el:
        el = _first_visible(driver.find_elements(By.XPATH, "//*[contains(translate(normalize-space(.),'ABCDEFGHIJKLMNOPQRSTUVWXYZ','abcdefghijklmnopqrstuvwxyz'),'amf')]"))
    if not el:
        step.snap("S_ERR_click_amf_subentry", html=True)
        raise Exception("click_amf_subentry: 'amf' not found")
    try:
        el.click()
    except Exception:
        driver.execute_script("arguments[0].click();", el)
    time.sleep(MED_SLEEP)
    step.snap("S_AFTER_click_amf_subentry", html=True)
    return True

# ---------------- Upload helpers ----------------
def upload_config_file(file_path):
    step.snap("S_BEFORE_upload", html=True)
    selectors = ["//input[@type='file']"]
    for sel in selectors:
        try:
            inp = driver.find_element(By.XPATH, sel)
            driver.execute_script("arguments[0].style.display='block'; arguments[0].style.visibility='visible';", inp)
            inp.send_keys(file_path)
            time.sleep(SHORT_SLEEP)
            step.snap("S_AFTER_upload", html=True)
            return True
        except Exception:
            continue
    step.snap("S_ERR_upload_no_input", html=True)
    raise Exception("upload_config_file: no file input found")

def click_import():
    """
    Robust Import click:
    - First, locate Import relative to Export
    - Then fallback to generic 'import' button search
    """
    step.snap("S_BEFORE_import", html=True)
    wait_for_no_overlay(wait=8)
    time.sleep(SHORT_SLEEP)

    import_btn = None

    # 1) Find Export and check siblings for Import
    try:
        exports = driver.find_elements(By.XPATH, "//*[contains(translate(normalize-space(.),'ABCDEFGHIJKLMNOPQRSTUVWXYZ','abcdefghijklmnopqrstuvwxyz'),'export')]")
        for exp in exports:
            if not exp.is_displayed():
                continue
            try:
                sibs = exp.find_elements(By.XPATH, "./preceding::*[contains(translate(normalize-space(.),'ABCDEFGHIJKLMNOPQRSTUVWXYZ','abcdefghijklmnopqrstuvwxyz'),'import')]")
                for s in sibs:
                    if s.is_displayed():
                        import_btn = s
                        break
            except Exception:
                continue
            if import_btn:
                break
    except Exception:
        pass

    # 2) Fallback: direct Import button search
    if not import_btn:
        try:
            nodes = driver.find_elements(By.XPATH,
                "//*[self::button or self::a or self::span or self::div]"
                "[contains(translate(normalize-space(.),'ABCDEFGHIJKLMNOPQRSTUVWXYZ','abcdefghijklmnopqrstuvwxyz'),'import')]"
            )
            import_btn = _first_visible(nodes)
        except Exception:
            import_btn = None

    # 3) If still not found, fail
    if not import_btn:
        step.snap("S_ERR_import_not_found", html=True)
        raise Exception("click_import: Import button not found (even near Export)")

    # 4) Try clicking Import
    try:
        import_btn.click()
    except Exception:
        try:
            driver.execute_script("arguments[0].click();", import_btn)
        except Exception:
            ActionChains(driver).move_to_element(import_btn).click(import_btn).perform()

    step.snap("S_AFTER_click_import", html=True)
    time.sleep(MED_SLEEP)
    return True


def apply_and_confirm():
    """
    Scroll to bottom, click Apply (blue button), then confirm Ok popup.
    """
    step.snap("S_BEFORE_apply", html=True)
    wait_for_no_overlay(wait=8)
    time.sleep(SHORT_SLEEP)

    apply_btn = None

    # 1) Scroll down in steps until Apply is found
    for _ in range(8):  # scroll up to 8 times
        try:
            candidates = driver.find_elements(
                By.XPATH,
                "//*[self::button or self::a or self::span or self::div]"
                "[contains(translate(normalize-space(.),'ABCDEFGHIJKLMNOPQRSTUVWXYZ','abcdefghijklmnopqrstuvwxyz'),'apply') "
                "or contains(@class,'apply')]"
            )
            apply_btn = _first_visible(candidates)
            if apply_btn:
                break
        except Exception:
            pass
        driver.execute_script("window.scrollBy(0, 500);")
        time.sleep(0.8)

    if not apply_btn:
        step.snap("S_ERR_apply_not_found", html=True)
        raise Exception("apply_and_confirm: Apply button not found at bottom")

    # 2) Click Apply (robustly)
    try:
        apply_btn.click()
    except Exception:
        try:
            driver.execute_script("arguments[0].click();", apply_btn)
        except Exception:
            ActionChains(driver).move_to_element(apply_btn).click(apply_btn).perform()
    step.snap("S_AFTER_click_apply", html=True)

    # 3) Wait for confirmation popup/modal
    time.sleep(1.5)
    ok_btn = None
    ok_xps = [
        "//button[contains(translate(normalize-space(.),'ABCDEFGHIJKLMNOPQRSTUVWXYZ','abcdefghijklmnopqrstuvwxyz'),'ok')]",
        "//button[contains(translate(normalize-space(.),'ABCDEFGHIJKLMNOPQRSTUVWXYZ','abcdefghijklmnopqrstuvwxyz'),'yes')]",
        "//button[contains(translate(normalize-space(.),'ABCDEFGHIJKLMNOPQRSTUVWXYZ','abcdefghijklmnopqrstuvwxyz'),'confirm')]",
    ]
    end = time.time() + 8
    while time.time() < end and not ok_btn:
        for xp in ok_xps:
            try:
                ok_btn = _first_visible(driver.find_elements(By.XPATH, xp))
                if ok_btn:
                    break
            except Exception:
                continue
        if not ok_btn:
            time.sleep(0.5)

    if ok_btn:
        try:
            ok_btn.click()
        except Exception:
            driver.execute_script("arguments[0].click();", ok_btn)
        step.snap("S_AFTER_click_ok", html=True)
        return True

    # fallback: native browser alert
    alert_text = handle_native_alerts(timeout=3, accept=True)
    if alert_text:
        print("Accepted native confirmation alert:", alert_text)
        step.snap("S_AFTER_alert_ok", html=True)
        return True

    step.snap("S_ERR_no_confirmation", html=True)
    raise Exception("apply_and_confirm: no confirmation popup after Apply")


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
            step.snap(f"S_DONE_upload_{fname}", html=True)

        print("All AMF uploads processed.")
    except Exception as e:
        print("Main flow error:", e)
        traceback.print_exc()
        step.snap("S_ERR_main_exception", html=True)
    finally:
        try:
            driver.quit()
        except Exception:
            pass

if __name__ == "__main__":
    main()
