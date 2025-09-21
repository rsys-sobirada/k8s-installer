#!/usr/bin/env python3
"""
gui_upload.py - AMF uploader with robust Import + Apply + confirmation handling,
plus result-capture and verification.

Flow:
  - Login
  - Configure -> AMF -> amf
  - Choose File -> Import
  - Apply (anchored near Fetch/Clear) -> Confirmation popup -> Ok
  - Capture result toast (success/fail) and save artifacts
  - If unclear, click Fetch and verify JSON snippet visible
  - Repeat for files in config_files

Screenshots + HTML saved to debug_screenshots/ for Jenkins artifacts.
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

# ---------------- Apply/Confirm helpers ----------------
def click_fetch():
    """
    Click the Fetch button if visible (used for refreshing UI after Apply).
    """
    step.snap("S_BEFORE_click_fetch", html=True)
    try:
        cand = _first_visible(driver.find_elements(By.XPATH, "//*[contains(translate(normalize-space(.),'ABCDEFGHIJKLMNOPQRSTUVWXYZ','abcdefghijklmnopqrstuvwxyz'),'fetch')]"))
        if cand:
            try:
                cand.click()
            except Exception:
                driver.execute_script("arguments[0].click();", cand)
            time.sleep(MED_SLEEP)
            step.snap("S_AFTER_click_fetch", html=True)
            return True
    except Exception:
        pass
    step.snap("S_ERR_no_fetch", html=True)
    return False

def apply_and_confirm():
    """
    Locate the blue Apply button (anchored near Fetch/Clear), click it,
    then confirm the Ok popup.
    """
    step.snap("S_BEFORE_apply", html=True)
    wait_for_no_overlay(wait=8)
    time.sleep(SHORT_SLEEP)

    apply_btn = None

    # 1) Look for Apply near Fetch or Clear
    try:
        fetch_btns = driver.find_elements(
            By.XPATH,
            "//*[self::button or self::a or self::span or self::div]"
            "[contains(translate(normalize-space(.),'ABCDEFGHIJKLMNOPQRSTUVWXYZ','abcdefghijklmnopqrstuvwxyz'),'fetch')]"
        )
        for fb in fetch_btns:
            try:
                sibs = fb.find_elements(
                    By.XPATH,
                    "./preceding::*[contains(translate(normalize-space(.),'ABCDEFGHIJKLMNOPQRSTUVWXYZ','abcdefghijklmnopqrstuvwxyz'),'apply')]"
                )
                for s in sibs:
                    if s.is_displayed():
                        apply_btn = s
                        break
            except Exception:
                continue
            if apply_btn:
                break
    except Exception:
        pass

    # 2) Fallback: global search
    if not apply_btn:
        try:
            nodes = driver.find_elements(
                By.XPATH,
                "//*[self::button or self::a or self::span or self::div]"
                "[contains(translate(normalize-space(.),'ABCDEFGHIJKLMNOPQRSTUVWXYZ','abcdefghijklmnopqrstuvwxyz'),'apply')]"
            )
            apply_btn = _first_visible(nodes)
        except Exception:
            apply_btn = None

    if not apply_btn:
        step.snap("S_ERR_apply_not_found", html=True)
        raise Exception("apply_and_confirm: Apply button not found")

    # 3) Try click Apply
    try:
        apply_btn.click()
        print("Clicked Apply using .click()")
    except Exception:
        try:
            driver.execute_script("arguments[0].click();", apply_btn)
            print("Clicked Apply using JS click")
        except Exception:
            ActionChains(driver).move_to_element(apply_btn).click(apply_btn).perform()
            print("Clicked Apply using ActionChains")

    step.snap("S_AFTER_click_apply", html=True)

    # 4) Wait for confirmation popup and click Ok
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

    # Fallback: native alert
    alert_text = handle_native_alerts(timeout=3, accept=True)
    if alert_text:
        print("Accepted native confirmation alert:", alert_text)
        step.snap("S_AFTER_alert_ok", html=True)
        return True

    step.snap("S_ERR_no_confirmation", html=True)
    raise Exception("apply_and_confirm: no confirmation popup after Apply")

# ---------------- Verification helpers ----------------
def verify_config_applied(json_file_path, lookup_keys=None, timeout=12):
    """
    Heuristic verification: after Apply, check page source for at least one
    key/value snippet from the uploaded JSON file. Returns True if found.
    """
    step.snap("S_VERIFY_BEFORE_check_page", html=True)
    snippets = []
    try:
        with open(json_file_path, 'r', encoding='utf-8') as fh:
            j = json.load(fh)
    except Exception:
        try:
            with open(json_file_path, 'r', encoding='utf-8') as fh:
                raw = fh.read()
            snippets = [raw.strip()[:200]]
        except Exception:
            snippets = []
    else:
        def collect_values(obj, depth=0):
            if len(snippets) >= 8 or depth > 4:
                return
            if isinstance(obj, dict):
                for k, v in obj.items():
                    if isinstance(v, (str, int, float)):
                        snippets.append(str(v))
                        snippets.append(str(k))
                    else:
                        collect_values(v, depth+1)
            elif isinstance(obj, list):
                for item in obj[:8]:
                    collect_values(item, depth+1)
        collect_values(j)

    if lookup_keys:
        for k in lookup_keys:
            if k and isinstance(k, str):
                snippets.append(k)

    if not snippets:
        # nothing to search for
        return False

    end = time.time() + timeout
    while time.time() < end:
        try:
            src = driver.page_source.lower()
            for s in snippets:
                if not s:
                    continue
                if s.lower() in src:
                    print("Verification snippet found in page:", s)
                    step.snap("S_VERIFY_snippet_found", html=True)
                    return True
        except Exception:
            pass
        time.sleep(0.5)

    step.snap("S_VERIFY_failed_pagesrc", html=True)
    try:
        fname = os.path.join(DEBUG_DIR, f"verify_pagesrc_{int(time.time())}.html")
        with open(fname, "w", encoding="utf-8") as fh:
            fh.write(driver.page_source)
        print("Saved verify pagesrc:", fname)
    except Exception:
        pass
    return False

def capture_result_toast(timeout=8, save_dir=DEBUG_DIR, success_keywords=None, fail_keywords=None):
    """
    Wait for a toast/modal message to appear after Apply and capture it.
    Returns: (status, text, png_path, html_path)
      status in {"success", "fail", "unknown", "none"}
    """
    if success_keywords is None:
        success_keywords = ["success", "applied", "saved", "completed", "persisted"]
    if fail_keywords is None:
        fail_keywords = ["error", "failed", "invalid", "exception", "not applied", "rejected"]

    step.snap("S_BEFORE_wait_toast", html=True)
    end = time.time() + timeout
    found_text = ""
    found_node = None

    toast_xpaths = [
        "//*[contains(@class,'toast') or contains(@class,'snack') or contains(@class,'notification') or contains(@class,'alert') or contains(@class,'message')]",
        "//*[contains(@class,'MuiSnackbar') or contains(@class,'MuiAlert') or contains(@class,'ant-notification') or contains(@class,'toastify')]",
        "//*[contains(@role,'alert') or contains(@role,'status') or contains(@role,'dialog')]",
        "//div[contains(@style,'position') and contains(translate(normalize-space(.),'ABCDEFGHIJKLMNOPQRSTUVWXYZ','abcdefghijklmnopqrstuvwxyz'),'success')]"
    ]

    # check quickly for native alert
    try:
        a = driver.switch_to.alert
        txt = a.text or ""
        try:
            a.accept()
        except Exception:
            pass
        found_text = txt.strip()
    except Exception:
        pass

    while time.time() < end and not found_text:
        try:
            for xp in toast_xpaths:
                nodes = driver.find_elements(By.XPATH, xp)
                for n in nodes:
                    try:
                        if not n.is_displayed():
                            continue
                        txt = (n.text or "").strip()
                        if not txt:
                            continue
                        found_text = txt
                        found_node = n
                        break
                    except Exception:
                        continue
                if found_text:
                    break
        except Exception:
            pass
        if not found_text:
            time.sleep(0.3)

    ts = int(time.time())
    status = "none"
    text_l = (found_text or "").lower()
    if text_l:
        if any(k in text_l for k in success_keywords):
            status = "success"
        elif any(k in text_l for k in fail_keywords):
            status = "fail"
        else:
            status = "unknown"

    png_name = os.path.join(save_dir, f"{ts}_RESULT_{status}.png")
    html_name = os.path.join(save_dir, f"{ts}_RESULT_{status}.html")
    txt_name = os.path.join(save_dir, f"{ts}_RESULT_{status}.txt")

    try:
        driver.save_screenshot(png_name)
    except Exception as e:
        print("Warning: screenshot save failed:", e)
    try:
        with open(html_name, "w", encoding="utf-8") as fh:
            fh.write(driver.page_source)
    except Exception as e:
        print("Warning: page-source save failed:", e)
    try:
        with open(txt_name, "w", encoding="utf-8") as fh:
            fh.write(found_text or "<no-text-detected>")
    except Exception:
        pass

    print(f"[RESULT_CAPTURE] status={status} text='{found_text}' screenshot={png_name} page={html_name}")
    return status, found_text, png_name, html_name

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

            # click import
            click_import()

            # click apply and confirm OK
            apply_and_confirm()
            step.snap("S_AFTER_apply_and_ok", html=True)

            # capture result toast (green success or error)
            status, msg, png, html = capture_result_toast(timeout=8)
            if status == "success":
                print("Apply reported success:", msg)
                # optional: still verify presence in UI
                verified = verify_config_applied(fpath, timeout=8)
                if verified:
                    print("Verified config snippet in UI.")
                else:
                    print("Verification snippet not found, but toast said success. Continuing (artifact saved).")
                step.snap(f"S_DONE_upload_{fname}", html=True)
                continue
            elif status == "fail":
                # fail early and save artifacts
                raise Exception("Apply reported failure: " + (msg or "<no-text>"))
            else:
                # unknown or none: try Fetch + verify
                print("No clear success toast; attempting Fetch + verify.")
                step.snap("S_BEFORE_fetch_for_verification", html=True)
                did_fetch = click_fetch()
                time.sleep(1.0)
                step.snap("S_AFTER_fetch_for_verification", html=True)
                verified = verify_config_applied(fpath, timeout=8)
                if verified:
                    print("Verified config snippet in UI after Fetch.")
                    step.snap(f"S_DONE_upload_{fname}", html=True)
                    continue
                else:
                    # save a special artifact and fail so we can debug
                    step.snap("S_VERIFY_final_failed", html=True)
                    raise Exception("Post-apply verification failed: config not visible in GUI. See debug artifacts.")

        print("All AMF uploads processed.")
    except Exception as e:
        print("Main flow error:", e)
        traceback.print_exc()
        step.snap("S_ERR_main_exception", html=True)
        # re-raise so CI can catch (optional)
        raise
    finally:
        try:
            time.sleep(0.8)
            driver.quit()
        except Exception:
            pass

if __name__ == "__main__":
    main()
