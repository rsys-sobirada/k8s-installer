#!/usr/bin/env python3
"""
gui_upload.py - AMF uploader (complete) with explicit Import click and import-effect verification.

Flow:
  - Login
  - Configure -> AMF -> amf
  - Choose File (absolute path) -> dispatch change event
  - Click Import -> handle overwrite confirmation if appears
  - Wait until imported config is visible in page (verify import effect)
  - Click Apply -> click Ok -> capture final toast -> verify config in UI
  - Save debug screenshots/html under debug_screenshots/
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
from selenium.common.exceptions import TimeoutException, NoSuchElementException

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
        "//*[contains(@class,'overlay') or contains(@class,'backdrop') or contains(@class,'modal-backdrop') or contains(@class,'cdk-overlay-backdrop') or contains(@class,'spinning')]",
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
        "//*[contains(translate(normalize-space(.),'ABCDEFGHIJKLMNOPQRSTUVWXYZ','abcdefghijklmnopqrstuvwxyz'),'configure')]"
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
    # try exact normalized text first, then fuzzy
    try:
        el = _first_visible(driver.find_elements(By.XPATH, "//*[translate(normalize-space(.),'ABCDEFGHIJKLMNOPQRSTUVWXYZ','abcdefghijklmnopqrstuvwxyz')='amf']"))
    except Exception:
        el = None
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

# ---------------- Upload helpers (original-style + fixes) ----------------
def upload_config_file(file_path):
    """
    Use original logic: compute absolute path, ensure file exists, then send_keys(abs_path).
    Dispatch a change event afterwards so SPA picks up the file.
    """
    step.snap("S_BEFORE_upload", html=True)
    abs_path = os.path.abspath(file_path)
    print("[DEBUG] Preparing to upload:", abs_path)
    if not os.path.exists(abs_path):
        step.snap("S_ERR_file_missing", html=True)
        raise FileNotFoundError(f"Config file not found: {abs_path}")

    # locate visible file input(s)
    candidates = []
    try:
        candidates = driver.find_elements(By.XPATH, "//input[@type='file']")
    except Exception:
        candidates = []

    if not candidates:
        # fallback to injecting input (rare)
        try:
            driver.execute_script("var i=document.createElement('input'); i.type='file'; i.id='tmp_upload_input'; i.style.display='block'; document.body.appendChild(i);")
            candidates = [driver.find_element(By.ID, "tmp_upload_input")]
        except Exception:
            step.snap("S_ERR_no_file_input", html=True)
            raise Exception("upload_config_file: no file input found and injection failed")

    inp = _first_visible(candidates)
    if not inp:
        inp = candidates[0]

    # ensure visible
    try:
        driver.execute_script("arguments[0].style.display='block'; arguments[0].style.visibility='visible';", inp)
    except Exception:
        pass

    # now send the absolute path
    try:
        inp.send_keys(abs_path)
    except Exception as e:
        # sometimes Selenium needs the absolute path; already tried; rethrow with clearer message
        raise Exception(f"upload_config_file: send_keys failed for {abs_path}: {e}")

    # dispatch change event so SPA sees it
    try:
        driver.execute_script("arguments[0].dispatchEvent(new Event('change', {bubbles:true}));", inp)
    except Exception:
        pass

    time.sleep(SHORT_SLEEP)
    step.snap("S_AFTER_upload", html=True)
    return True

def handle_overwrite_confirmation(timeout=8):
    """
    After clicking Import, handle any overwrite/replace dialog automatically.
    """
    step.snap("S_WAIT_OVERWRITE_DIALOG", html=True)
    end = time.time() + timeout
    dialog_keywords = ["overwrite", "replace", "already exists", "are you sure", "confirm replace", "replace existing"]
    button_texts = ["overwrite", "replace", "yes", "confirm", "proceed", "ok", "apply"]

    while time.time() < end:
        try:
            mods = driver.find_elements(By.XPATH, "//*[contains(@class,'modal') or contains(@class,'dialog') or contains(@role,'dialog') or contains(@class,'popup')]")
        except Exception:
            mods = []
        for mod in mods:
            try:
                if not mod.is_displayed():
                    continue
                txt = (mod.text or "").lower()
                if any(k in txt for k in dialog_keywords):
                    for bt in button_texts:
                        try:
                            btns = mod.find_elements(By.XPATH, f".//*[contains(translate(normalize-space(.),'ABCDEFGHIJKLMNOPQRSTUVWXYZ','abcdefghijklmnopqrstuvwxyz'),'{bt}')]")
                        except Exception:
                            btns = []
                        for b in btns:
                            try:
                                if not b.is_displayed():
                                    continue
                                try:
                                    b.click()
                                except Exception:
                                    try:
                                        driver.execute_script("arguments[0].click();", b)
                                    except Exception:
                                        ActionChains(driver).move_to_element(b).click(b).perform()
                                step.snap("S_HANDLED_overwrite_button", html=True)
                                time.sleep(MED_SLEEP)
                                return True
                            except Exception:
                                continue
        # native alert fallback
        try:
            a = handle_native_alerts(timeout=0.5, accept=False)
            if a:
                handle_native_alerts(timeout=1, accept=True)
                step.snap("S_HANDLED_native_overwrite_alert", html=True)
                return True
        except Exception:
            pass
        time.sleep(0.4)
    return False

def click_import():
    """
    Click the Import button; first try to find it near Export (stable), otherwise generic import search.
    Then handle overwrite confirmation if appears.
    """
    step.snap("S_BEFORE_import", html=True)
    wait_for_no_overlay(wait=8)
    time.sleep(SHORT_SLEEP)

    import_btn = None
    try:
        exports = driver.find_elements(By.XPATH, "//*[contains(translate(normalize-space(.),'ABCDEFGHIJKLMNOPQRSTUVWXYZ','abcdefghijklmnopqrstuvwxyz'),'export')]")
    except Exception:
        exports = []

    for exp in exports:
        try:
            if not exp.is_displayed():
                continue
            try:
                sibs = exp.find_elements(By.XPATH, "./preceding::*[contains(translate(normalize-space(.),'ABCDEFGHIJKLMNOPQRSTUVWXYZ','abcdefghijklmnopqrstuvwxyz'),'import')]")
            except Exception:
                sibs = []
            for s in sibs:
                if s.is_displayed():
                    import_btn = s
                    break
            if import_btn:
                break
        except Exception:
            continue

    if not import_btn:
        # generic search
        try:
            nodes = driver.find_elements(By.XPATH, "//*[self::button or self::a or self::span or self::div][contains(translate(normalize-space(.),'ABCDEFGHIJKLMNOPQRSTUVWXYZ','abcdefghijklmnopqrstuvwxyz'),'import')]")
            import_btn = _first_visible(nodes)
        except Exception:
            import_btn = None

    if not import_btn:
        step.snap("S_ERR_import_not_found", html=True)
        raise Exception("click_import: Import button not found")

    # Click it (robust)
    try:
        import_btn.click()
    except Exception:
        try:
            driver.execute_script("arguments[0].click();", import_btn)
        except Exception:
            ActionChains(driver).move_to_element(import_btn).click(import_btn).perform()

    step.snap("S_AFTER_click_import", html=True)
    # handle potential overwrite confirmation
    handled = handle_overwrite_confirmation(timeout=8)
    if handled:
        print("Overwrite confirmation handled.")
    else:
        time.sleep(MED_SLEEP)
    return True

# ---------------- Import-effect verification ----------------
def wait_for_import_effect(json_file, timeout=12):
    """
    Heuristic: check that keys/values from JSON appear in page source after Import.
    This ensures the selected configuration is displayed in the GUI (overwrite effect).
    """
    step.snap("S_VERIFY_BEFORE_import_effect", html=True)
    try:
        with open(json_file, "r", encoding="utf-8") as fh:
            raw = fh.read(400)
    except Exception:
        raw = ""

    candidates = []
    # try to parse JSON and pick some meaningful tokens
    try:
        j = json.loads(raw)
        if isinstance(j, dict):
            # choose some keys and values
            keys = list(j.keys())[:4]
            for k in keys:
                candidates.append(str(k))
                v = j.get(k)
                if isinstance(v, (str, int, float)) and len(str(v)) > 2:
                    candidates.append(str(v))
        elif isinstance(j, list) and j:
            # pick some values from first element
            first = j[0]
            if isinstance(first, dict):
                for k, v in list(first.items())[:4]:
                    candidates.append(str(k))
                    if isinstance(v, (str, int, float)):
                        candidates.append(str(v))
    except Exception:
        # fallback: extract alphanumeric tokens
        tokens = re.findall(r'[A-Za-z0-9_\-]{4,}', raw)
        candidates.extend(tokens[:6])

    candidates = [c for c in candidates if c and len(c) > 3]
    if not candidates:
        step.snap("S_ERR_no_candidates_for_import_verify", html=True)
        raise Exception("No verification candidates found in JSON to verify import effect")

    end = time.time() + timeout
    while time.time() < end:
        try:
            src = driver.page_source.lower()
            for c in candidates:
                if c.lower() in src:
                    step.snap("S_IMPORT_effect_detected", html=True)
                    print("Import effect detected with token:", c)
                    return True
        except Exception:
            pass
        time.sleep(0.5)

    step.snap("S_IMPORT_effect_missing", html=True)
    raise Exception("Import did not update GUI (import-effect not detected)")

# ---------------- Apply & confirmation ----------------
def click_fetch():
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
    step.snap("S_BEFORE_apply", html=True)
    wait_for_no_overlay(wait=8)
    time.sleep(SHORT_SLEEP)

    # find Apply (anchored near Fetch/Clear)
    apply_btn = None
    try:
        fetch_btns = driver.find_elements(By.XPATH, "//*[contains(translate(normalize-space(.),'ABCDEFGHIJKLMNOPQRSTUVWXYZ','abcdefghijklmnopqrstuvwxyz'),'fetch')]")
    except Exception:
        fetch_btns = []
    for fb in fetch_btns:
        try:
            sibs = fb.find_elements(By.XPATH, "./preceding::*[contains(translate(normalize-space(.),'ABCDEFGHIJKLMNOPQRSTUVWXYZ','abcdefghijklmnopqrstuvwxyz'),'apply')]")
        except Exception:
            sibs = []
        for s in sibs:
            if s.is_displayed():
                apply_btn = s
                break
        if apply_btn:
            break

    if not apply_btn:
        nodes = driver.find_elements(By.XPATH, "//*[self::button or self::a or self::span or self::div][contains(translate(normalize-space(.),'ABCDEFGHIJKLMNOPQRSTUVWXYZ','abcdefghijklmnopqrstuvwxyz'),'apply')]")
        apply_btn = _first_visible(nodes)

    if not apply_btn:
        step.snap("S_ERR_apply_not_found", html=True)
        raise Exception("apply_and_confirm: Apply button not found")

    # click apply robustly
    try:
        apply_btn.click()
    except Exception:
        try:
            driver.execute_script("arguments[0].click();", apply_btn)
        except Exception:
            ActionChains(driver).move_to_element(apply_btn).click(apply_btn).perform()

    step.snap("S_AFTER_click_apply", html=True)

    # Confirmation Ok handling
    time.sleep(1.2)
    ok_btn = _first_visible(driver.find_elements(By.XPATH, "//button[contains(translate(normalize-space(.),'ABCDEFGHIJKLMNOPQRSTUVWXYZ','abcdefghijklmnopqrstuvwxyz'),'ok')]"))
    if ok_btn:
        try:
            ok_btn.click()
        except Exception:
            driver.execute_script("arguments[0].click();", ok_btn)
        step.snap("S_AFTER_click_ok", html=True)
    else:
        alt = handle_native_alerts(timeout=3, accept=True)
        if alt:
            step.snap("S_AFTER_native_alert_ok", html=True)

    # Wait for final result popup (success/fail) for a short window
    step.snap("S_WAITING_for_final_result", html=True)
    end = time.time() + 12
    final_text = ""
    while time.time() < end:
        try:
            nodes = driver.find_elements(By.XPATH, "//*[contains(@class,'toast') or contains(@class,'snack') or contains(@class,'notification') or contains(@role,'alert') or contains(@role,'status') or contains(@class,'message') or contains(@class,'dialog')]")
            for n in nodes:
                try:
                    if not n.is_displayed():
                        continue
                    t = (n.text or "").strip()
                    if not t:
                        continue
                    if any(k in t.lower() for k in ("success", "applied", "saved", "completed", "persisted", "error", "failed", "rejected")):
                        final_text = t
                        break
                except Exception:
                    continue
            if final_text:
                break
        except Exception:
            pass
        time.sleep(0.5)

    if final_text:
        step.snap("S_FINAL_result_popup", html=True)
        outf = os.path.join(DEBUG_DIR, f"apply_final_result_{int(time.time())}.txt")
        try:
            with open(outf, "w", encoding="utf-8") as fh:
                fh.write(final_text)
        except Exception:
            pass
        print("Final Apply result:", final_text)
    else:
        step.snap("S_ERR_no_final_popup", html=True)
        print("No final popup detected after Apply (continuing)")

    return True

# ---------------- Verification helpers ----------------
def verify_config_applied(json_file_path, lookup_keys=None, timeout=10):
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
            if isinstance(k, str) and k:
                snippets.append(k)

    if not snippets:
        return False

    end = time.time() + timeout
    while time.time() < end:
        try:
            src = driver.page_source.lower()
            for s in snippets:
                if not s:
                    continue
                if s.lower() in src:
                    step.snap("S_VERIFY_snippet_found", html=True)
                    print("Verified snippet found:", s)
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

def capture_result_toast(timeout=8, save_dir=DEBUG_DIR):
    step.snap("S_BEFORE_wait_toast", html=True)
    end = time.time() + timeout
    found_text = ""
    while time.time() < end and not found_text:
        try:
            nodes = driver.find_elements(By.XPATH, "//*[contains(@class,'toast') or contains(@class,'snack') or contains(@class,'notification') or contains(@role,'alert') or contains(@role,'status') or contains(@class,'message')]")
            for n in nodes:
                try:
                    if not n.is_displayed():
                        continue
                    txt = (n.text or "").strip()
                    if txt:
                        found_text = txt
                        break
                except Exception:
                    continue
            if found_text:
                break
        except Exception:
            pass
        time.sleep(0.3)

    ts = int(time.time())
    status = "none"
    text_l = (found_text or "").lower()
    if text_l:
        if any(k in text_l for k in ["success", "applied", "saved", "completed", "persisted"]):
            status = "success"
        elif any(k in text_l for k in ["error", "failed", "invalid", "rejected"]):
            status = "fail"
        else:
            status = "unknown"

    png_name = os.path.join(save_dir, f"{ts}_RESULT_{status}.png")
    html_name = os.path.join(save_dir, f"{ts}_RESULT_{status}.html")
    txt_name = os.path.join(save_dir, f"{ts}_RESULT_{status}.txt")

    try:
        driver.save_screenshot(png_name)
    except Exception:
        pass
    try:
        with open(html_name, "w", encoding="utf-8") as fh:
            fh.write(driver.page_source)
    except Exception:
        pass
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
        u = driver.find_element(By.XPATH, "//input[@type='text' or @type='email' or contains(@name,'user')]")
        p = driver.find_element(By.XPATH, "//input[@type='password' or contains(@name,'pass')]")
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

        # ensure config dir exists
        if not os.path.isdir(CONFIG_DIR):
            raise Exception(f"CONFIG_DIR '{CONFIG_DIR}' not found")
        files = sorted(os.listdir(CONFIG_DIR))
        if not files:
            print("No files found in", CONFIG_DIR)

        for fname in files:
            if not fname.lower().endswith("_amf.json"):
                continue
            fpath = os.path.abspath(os.path.join(CONFIG_DIR, fname))
            print("Processing:", fpath)
            step.snap(f"S_START_upload_{fname}", html=True)

            # Upload file (original safe logic)
            upload_config_file(fpath)

            # Click Import (explicit)
            click_import()

            # Wait for import effect (ensure GUI shows imported config before Apply)
            wait_for_import_effect(fpath, timeout=12)

            # Click Apply and confirm
            apply_and_confirm()

            # Capture final toast and verify presence in UI
            status, msg, png, html = capture_result_toast(timeout=8)
            if status == "success":
                print("Apply reported success:", msg)
                verified = verify_config_applied(fpath, timeout=8)
                if verified:
                    print("Verified config snippet in UI.")
                else:
                    print("Verification snippet not found, but toast said success.")
            elif status == "fail":
                raise Exception("Apply reported failure: " + (msg or "<no-text>"))
            else:
                print("No clear result toast; attempting Fetch + verify")
                click_fetch()
                time.sleep(1.0)
                verified = verify_config_applied(fpath, timeout=8)
                if not verified:
                    step.snap("S_VERIFY_final_failed", html=True)
                    raise Exception("Post-apply verification failed: config not visible in GUI. See debug artifacts.")
            step.snap(f"S_DONE_upload_{fname}", html=True)

        print("All AMF uploads processed.")
    except Exception as e:
        print("Main flow error:", e)
        traceback.print_exc()
        step.snap("S_ERR_main_exception", html=True)
        raise
    finally:
        try:
            time.sleep(0.8)
            driver.quit()
        except Exception:
            pass

if __name__ == "__main__":
    main()
