#!/usr/bin/env python3
# gui_upload.py - Patched to reliably click AMF (robust strategies + screenshots)
# Flow: Login -> Configure -> AMF -> amf (robust) -> Choose File -> Import -> scroll -> Apply -> Ok

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
from selenium.common.exceptions import TimeoutException, WebDriverException

# ---------------- Config ----------------
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

# ---------------- Utilities and Debugging ----------------
class StepCapture:
    def __init__(self, base_dir):
        self.base_dir = base_dir
        self.counter = 0
        os.makedirs(base_dir, exist_ok=True)

    def _safe_name(self, label):
        s = re.sub(r'[^0-9A-Za-z._-]+', '_', str(label))[:80]
        return s or "step"

    def snap(self, label, html=False):
        self.counter += 1
        base = f"{int(time.time())}_{self.counter:03d}_{self._safe_name(label)}"
        png = os.path.join(self.base_dir, base + ".png")
        try:
            driver.save_screenshot(png)
            print(f"[CAPTURE] {png}")
        except Exception as e:
            print("Screenshot failed:", e)
        if html:
            try:
                htm = os.path.join(self.base_dir, base + ".html")
                with open(htm, "w", encoding="utf-8") as fh:
                    fh.write(driver.page_source)
                print(f"[CAPTURE] {htm}")
            except Exception as e:
                print("Save page-source failed:", e)

step = StepCapture(DEBUG_DIR)

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
        print("Alert handling error:", e)
        return ""

def _first_visible(elements):
    for e in elements:
        try:
            if e.is_displayed():
                return e
        except Exception:
            continue
    return None

# ---------------- Login/Navigation Helpers ----------------
def robust_login():
    driver.get(URL)
    step.snap("S_LOGIN_page_open", html=True)
    wait_document_ready(20)
    time.sleep(MED_SLEEP)
    step.snap("S_LOGIN_page_loaded", html=True)

    # Try to locate username/password in page or iframe
    u = None; p = None
    try:
        u = driver.find_element(By.XPATH, "//input[@type='text' or @type='email' or contains(translate(@name,'ABCDEFGHIJKLMNOPQRSTUVWXYZ','abcdefghijklmnopqrstuvwxyz'),'user')]")
    except Exception:
        pass
    try:
        p = driver.find_element(By.XPATH, "//input[@type='password' or contains(translate(@name,'ABCDEFGHIJKLMNOPQRSTUVWXYZ','abcdefghijklmnopqrstuvwxyz'),'pass')]")
    except Exception:
        pass

    if not u or not p:
        # try searching more broadly
        try:
            u = WebDriverWait(driver, 8).until(EC.presence_of_element_located((By.XPATH, "//input[@type='text' or @type='email' or contains(translate(@placeholder,'ABCDEFGHIJKLMNOPQRSTUVWXYZ','abcdefghijklmnopqrstuvwxyz'),'user')]")))
            p = WebDriverWait(driver, 8).until(EC.presence_of_element_located((By.XPATH, "//input[@type='password']")))
        except Exception:
            pass

    if not u or not p:
        step.snap("S_LOGIN_no_fields", html=True)
        raise Exception("Login fields not found on login page.")

    try:
        u.clear(); u.send_keys(USERNAME)
        p.clear(); p.send_keys(PASSWORD)
        time.sleep(SHORT_SLEEP)
        p.send_keys(Keys.RETURN)
        time.sleep(MED_SLEEP)
        step.snap("S_LOGIN_after_submit", html=True)
        wait_document_ready(20)
        time.sleep(MED_SLEEP)
    except Exception as e:
        step.snap("S_LOGIN_error", html=True)
        raise

# generic helper to click element by visible text (case-insensitive)
def find_and_click_by_text(text, timeout=12):
    t = text.lower()
    xpaths = [
        f"//*[contains(translate(normalize-space(.), 'ABCDEFGHIJKLMNOPQRSTUVWXYZ', 'abcdefghijklmnopqrstuvwxyz'), '{t}')]",
        f"//a[contains(translate(normalize-space(.), 'ABCDEFGHIJKLMNOPQRSTUVWXYZ', 'abcdefghijklmnopqrstuvwxyz'), '{t}')]",
        f"//button[contains(translate(normalize-space(.), 'ABCDEFGHIJKLMNOPQRSTUVWXYZ', 'abcdefghijklmnopqrstuvwxyz'), '{t}')]"
    ]
    for xp in xpaths:
        try:
            el = WebDriverWait(driver, timeout).until(EC.element_to_be_clickable((By.XPATH, xp)))
            driver.execute_script("arguments[0].scrollIntoView({block:'center', inline:'center'});", el)
            time.sleep(SHORT_SLEEP)
            try:
                el.click()
            except Exception:
                driver.execute_script("arguments[0].click();", el)
            time.sleep(SHORT_SLEEP)
            step.snap(f"S_CLICKED_{text}", html=True)
            return el
        except Exception:
            continue
    raise Exception(f"Clickable element with text '{text}' not found.")

# ---------------- Robust AMF click helper ----------------
def wait_for_no_overlay(wait=12):
    overlay_xps = [
        "//*[contains(@class,'overlay') and not(contains(@style,'display:none'))]",
        "//*[contains(@class,'modal-backdrop') or contains(@class,'cdk-overlay-backdrop') or contains(@class,'MuiBackdrop-root')]",
        "//*[contains(@class,'spinner') or contains(@class,'loading') or contains(@class,'progress')]"
    ]
    end = time.time() + wait
    while time.time() < end:
        visible = False
        for xp in overlay_xps:
            try:
                els = driver.find_elements(By.XPATH, xp)
                for e in els:
                    try:
                        if e.is_displayed():
                            visible = True
                            break
                    except Exception:
                        continue
                if visible:
                    break
            except Exception:
                continue
        if not visible:
            return True
        time.sleep(0.25)
    return False

def ensure_click_amf(timeout=18):
    """
    Robustly click the 'amf' entry in the Configure -> AMF section.
    Tries:
      - Wait for overlays to finish
      - Several XPath strategies (exact, contains, anchors, li)
      - Scroll into view, ActionChains click, JS click fallback
      - Takes snapshots at important points
    """
    step.snap("S_BEFORE_ensure_click_amf", html=True)
    wait_for_no_overlay(wait=timeout if timeout < 25 else 25)
    time.sleep(SHORT_SLEEP)

    candidate_xpaths = [
        "//*[translate(normalize-space(.),'ABCDEFGHIJKLMNOPQRSTUVWXYZ','abcdefghijklmnopqrstuvwxyz')='amf']",
        "//*[self::a or self::button or self::span or self::div][contains(translate(normalize-space(.),'ABCDEFGHIJKLMNOPQRSTUVWXYZ','abcdefghijklmnopqrstuvwxyz'),'amf')]",
        "//li[.//text()[contains(translate(. ,'ABCDEFGHIJKLMNOPQRSTUVWXYZ','abcdefghijklmnopqrstuvwxyz'),'amf')]]",
        "//nav//a[contains(translate(normalize-space(.),'ABCDEFGHIJKLMNOPQRSTUVWXYZ','abcdefghijklmnopqrstuvwxyz'),'amf')]",
        "//*[@aria-label and contains(translate(@aria-label,'ABCDEFGHIJKLMNOPQRSTUVWXYZ','abcdefghijklmnopqrstuvwxyz'),'amf')]",
        "//*[@title and contains(translate(@title,'ABCDEFGHIJKLMNOPQRSTUVWXYZ','abcdefghijklmnopqrstuvwxyz'),'amf')]",
    ]

    last_err = None
    for xp in candidate_xpaths:
        try:
            elems = driver.find_elements(By.XPATH, xp)
            if not elems:
                continue
            target = _first_visible(elems)
            if not target:
                continue

            try:
                driver.execute_script("arguments[0].scrollIntoView({block:'center', inline:'nearest'});", target)
            except Exception:
                pass
            time.sleep(SHORT_SLEEP)

            # Try click via ActionChains
            try:
                actions = ActionChains(driver)
                actions.move_to_element(target).pause(0.15).click(target).perform()
                time.sleep(SHORT_SLEEP)
                step.snap(f"S_CLICK_amf_actions_{xp}", html=True)
                print("Clicked AMF using ActionChains:", xp)
                return True
            except Exception as e_actions:
                # fallback JS click
                try:
                    driver.execute_script("arguments[0].click();", target)
                    time.sleep(SHORT_SLEEP)
                    step.snap(f"S_CLICK_amf_js_{xp}", html=True)
                    print("Clicked AMF via JS fallback:", xp)
                    return True
                except Exception as e_js:
                    last_err = (e_actions, e_js)
                    step.snap(f"S_ERR_click_amf_failed_{xp}", html=True)
                    print("Click attempts failed for xp:", xp, "errors:", e_actions, e_js)
                    continue
        except Exception as e:
            last_err = e
            step.snap("S_ERR_click_amf_find_exception", html=True)
            print("Exception searching for AMF via xpath", xp, ":", e)
            continue

    # Final fallback: try clicking any element that contains 'amf' by small fuzzy search across elements
    try:
        candidates = driver.find_elements(By.XPATH, "//*[contains(translate(normalize-space(.),'ABCDEFGHIJKLMNOPQRSTUVWXYZ','abcdefghijklmnopqrstuvwxyz'),'amf')]")
        for c in candidates:
            try:
                if c.is_displayed():
                    driver.execute_script("arguments[0].scrollIntoView({block:'center'});", c)
                    try:
                        c.click()
                    except Exception:
                        driver.execute_script("arguments[0].click();", c)
                    time.sleep(SHORT_SLEEP)
                    step.snap("S_CLICK_amf_fuzzy", html=True)
                    print("Clicked fuzzy AMF element")
                    return True
            except Exception:
                continue
    except Exception:
        pass

    # Nothing worked
    step.snap("S_ERR_click_amf_final", html=True)
    raise Exception(f"ensure_click_amf: unable to click AMF; last error: {last_err}")

# ---------------- File upload helper ----------------
def upload_config_file(file_path):
    step.snap("S_UPLOAD_before", html=True)
    selectors = [
        "//input[@type='file']",
        "//input[contains(@class,'file') and @type='file']",
        "//input[contains(@id,'file') and @type='file']",
    ]
    for sel in selectors:
        try:
            inp = driver.find_element(By.XPATH, sel)
            driver.execute_script("arguments[0].style.display='block'; arguments[0].style.visibility='visible';", inp)
            inp.send_keys(file_path)
            time.sleep(SHORT_SLEEP)
            step.snap("S_UPLOAD_after_sendkeys", html=True)
            return
        except Exception:
            continue

    # Fallback: create an injected input and send keys
    try:
        uid = f"tmp_file_in_{int(time.time())}"
        js = "var i=document.createElement('input'); i.type='file'; i.id=arguments[0]; i.style.display='block'; document.body.appendChild(i); return i;"
        driver.execute_script(js, uid)
        tmp = driver.find_element(By.ID, uid)
        tmp.send_keys(file_path)
        time.sleep(SHORT_SLEEP)
        step.snap("S_UPLOAD_after_injected", html=True)
        return
    except Exception as e:
        step.snap("S_ERR_upload_no_input", html=True)
        raise Exception("upload_config_file: could not find or inject file input") from e

# ---------------- Import / Apply ----------------
def click_import():
    step.snap("S_BEFORE_import", html=True)
    texts = ["persist configurations", "persist", "import", "upload", "persist config", "persist configuration"]
    for t in texts:
        try:
            btn = driver.find_element(By.XPATH, f"//*[contains(translate(normalize-space(.), 'ABCDEFGHIJKLMNOPQRSTUVWXYZ','abcdefghijklmnopqrstuvwxyz'), '{t}')]")
            if btn and btn.is_displayed():
                try:
                    btn.click()
                except Exception:
                    driver.execute_script("arguments[0].click();", btn)
                time.sleep(MED_SLEEP)
                step.snap("S_AFTER_import", html=True)
                handle_native_alerts(timeout=6, accept=True)
                return True
        except Exception:
            continue
    step.snap("S_ERR_import_not_found", html=True)
    raise Exception("click_import: import/persist button not found")

def click_apply():
    step.snap("S_BEFORE_apply", html=True)
    # scroll a bit to ensure Apply visible
    try:
        driver.execute_script("window.scrollBy(0, 300);")
        time.sleep(0.4)
    except Exception:
        pass
    # search for apply button
    words = ["apply", "apply changes", "confirm", "ok", "yes"]
    for w in words:
        try:
            btn = driver.find_element(By.XPATH, f"//*[contains(translate(normalize-space(.), 'ABCDEFGHIJKLMNOPQRSTUVWXYZ','abcdefghijklmnopqrstuvwxyz'), '{w}')]")
            if btn and btn.is_displayed():
                try:
                    driver.execute_script("arguments[0].scrollIntoView({block:'center'});", btn)
                except Exception:
                    pass
                time.sleep(SHORT_SLEEP)
                try:
                    btn.click()
                except Exception:
                    driver.execute_script("arguments[0].click();", btn)
                time.sleep(MED_SLEEP)
                step.snap("S_AFTER_apply", html=True)
                handle_native_alerts(timeout=6, accept=True)
                return True
        except Exception:
            continue
    step.snap("S_ERR_apply_not_found", html=True)
    raise Exception("click_apply: Apply button not found")

# ---------------- Main flow ----------------
def main():
    try:
        print("Starting GUI upload run")
        robust_login()
        step.snap("S_AFTER_login_main", html=True)
        time.sleep(MED_SLEEP)

        # Open Configure menu - attempt to click 'Configure' navigation
        try:
            find_and_click_by_text("configure", timeout=12)
        except Exception as e:
            print("Failed to click Configure via simple text click, trying fallback...", e)
            # fallback more targeted
            try:
                el = driver.find_element(By.XPATH, "//*[contains(translate(normalize-space(.), 'ABCDEFGHIJKLMNOPQRSTUVWXYZ','abcdefghijklmnopqrstuvwxyz'), 'configure')]")
                driver.execute_script("arguments[0].click();", el)
            except Exception:
                raise

        time.sleep(SHORT_SLEEP)
        step.snap("S_AFTER_open_configure", html=True)

        # Click AMF category (top/main)
        try:
            find_and_click_by_text("amf", timeout=8)
        except Exception:
            # sometimes the category is shown on the left; ensure robust click
            print("Top AMF click failed — using ensure_click_amf fallback")
        time.sleep(SHORT_SLEEP)

        # Robustly click left-side 'amf' entry
        try:
            ensure_click_amf()
        except Exception as e:
            print("ensure_click_amf failed:", e)
            # continue but capture state
            step.snap("S_AMF_click_failed_continuing", html=True)
            raise

        time.sleep(MED_SLEEP)
        step.snap("S_AFTER_amf_selected", html=True)

        # Find AMF file(s) and upload
        if not os.path.isdir(CONFIG_DIR):
            raise Exception(f"CONFIG_DIR '{CONFIG_DIR}' not found")

        files = sorted(os.listdir(CONFIG_DIR))
        for fname in files:
            if not fname.lower().endswith("_amf.json"):
                continue
            fpath = os.path.abspath(os.path.join(CONFIG_DIR, fname))
            print("Processing file:", fpath)
            step.snap(f"S_START_upload_{fname}", html=True)

            # Choose File
            upload_config_file(fpath)

            # Import / Persist
            click_import()

            # Scroll a bit (to make Apply visible) and click Apply
            # Some UIs place Apply toward bottom
            try:
                driver.execute_script("window.scrollTo(0, document.body.scrollHeight - 200);")
            except Exception:
                pass
            time.sleep(SHORT_SLEEP)

            click_apply()

            # Click Ok / Confirm in popup if present (modal button)
            try:
                # prefer explicit 'ok' button in modal
                okbtn = driver.find_element(By.XPATH, "//*[contains(translate(normalize-space(.), 'ABCDEFGHIJKLMNOPQRSTUVWXYZ','abcdefghijklmnopqrstuvwxyz'), 'ok') and (self::button or self::a)]")
                if okbtn and okbtn.is_displayed():
                    try:
                        okbtn.click()
                    except Exception:
                        driver.execute_script("arguments[0].click();", okbtn)
                    time.sleep(SHORT_SLEEP)
                    step.snap("S_AFTER_ok_click", html=True)
            except Exception:
                # try native alert handled earlier; otherwise ignore
                pass

            # wait for success notice (toast)
            end = time.time() + (8 if FAST_MODE else 20)
            success_found = False
            while time.time() < end:
                try:
                    nodes = driver.find_elements(By.XPATH, "//*[contains(@class,'toast') or contains(@class,'snack') or contains(@class,'alert') or contains(@class,'message')]")
                    for n in nodes:
                        try:
                            if n.is_displayed() and n.text and any(k in n.text.lower() for k in ("success", "applied", "saved", "persisted", "completed")):
                                success_found = True
                                break
                        except Exception:
                            continue
                    if success_found:
                        break
                except Exception:
                    pass
                time.sleep(0.4)

            if success_found:
                print("Upload indicated success for:", fname)
            else:
                print("No explicit success toast detected (check screenshots) for:", fname)
            step.snap(f"S_DONE_upload_{fname}", html=True)

        print("All AMF uploads processed.")

    except Exception as e:
        print("Main flow error:", e)
        traceback.print_exc()
        step.snap("S_ERR_main_exception", html=True)
    finally:
        try:
            time.sleep(1.0)
            driver.quit()
        except Exception:
            pass

if __name__ == "__main__":
    main()
