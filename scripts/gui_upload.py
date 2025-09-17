#!/usr/bin/env python3
"""
gui_upload.py - Robust AMF config uploader with strong click/fallback logic.

Flow:
  1. Login
  2. Configure (robust click)
  3. AMF (click top category then robust left 'amf' entry)
  4. Choose File (upload _amf.json)
  5. Import / Persist
  6. Scroll & Apply
  7. Ok / confirmation
  8. Repeat for files in config_files

Saves debug screenshots / HTML into debug_screenshots/ for Jenkins archival.
Set HEADLESS=0 environment variable to run with browser visible (recommended for initial debug).
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
from selenium.common.exceptions import TimeoutException, WebDriverException

# ---------------- CONFIG ----------------
URL = os.environ.get("EMS_URL", "https://172.27.28.193.nip.io/ems/login")
USERNAME = os.environ.get("EMS_USER", "root")
PASSWORD = os.environ.get("EMS_PASS", "root123")
CONFIG_DIR = os.environ.get("CONFIG_DIR", "config_files")
DEBUG_DIR = os.environ.get("DEBUG_DIR", "debug_screenshots")
os.makedirs(DEBUG_DIR, exist_ok=True)

HEADLESS = os.environ.get("HEADLESS", "1") != "0"   # set HEADLESS=0 to see browser
FAST_MODE = os.environ.get("FAST_MODE", "0") == "1"

SHORT_SLEEP = 0.2 if FAST_MODE else 0.6
MED_SLEEP   = 0.6 if FAST_MODE else 1.2
LONG_SLEEP  = 1.2 if FAST_MODE else 3.0

# ---------------- DRIVER SETUP ----------------
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
        s = re.sub(r"[^0-9A-Za-z._-]+", "_", str(s))[:80]
        return s or "step"

    def snap(self, label, html=False):
        self.counter += 1
        timestamp = int(time.time())
        name = f"{timestamp}_{self.counter:03d}_{self._clean(label)}"
        png = os.path.join(self.base_dir, name + ".png")
        try:
            driver.save_screenshot(png)
            print(f"[CAPTURE] {png}")
        except Exception as e:
            print("Screenshot failed:", e)
        if html:
            try:
                htm = os.path.join(self.base_dir, name + ".html")
                with open(htm, "w", encoding="utf-8") as fh:
                    fh.write(driver.page_source)
                print(f"[CAPTURE] {htm}")
            except Exception as e:
                print("Save page-source failed:", e)

step = StepCapture(DEBUG_DIR)

# ---------------- small utilities ----------------
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
        print("Alert handling error:", e)
        return ""

# ---------------- Overlay wait ----------------
def wait_for_no_overlay(wait=12):
    overlay_xps = [
        "//*[contains(@class,'overlay') or contains(@class,'backdrop') or contains(@class,'modal-backdrop') or contains(@class,'cdk-overlay-backdrop') or contains(@class,'MuiBackdrop-root')]",
        "//*[contains(@class,'spinner') or contains(@class,'loading') or contains(@class,'progress')]"
    ]
    end = time.time() + wait
    while time.time() < end:
        visible = False
        for xp in overlay_xps:
            try:
                for e in driver.find_elements(By.XPATH, xp):
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

# ---------------- robust click helpers ----------------
def click_element_by_text(text, timeout=12):
    """
    Try to click an element that contains the given text (case-insensitive).
    Returns the clicked element or raises.
    """
    t = text.lower()
    xpaths = [
        f"//*[contains(translate(normalize-space(.),'ABCDEFGHIJKLMNOPQRSTUVWXYZ','abcdefghijklmnopqrstuvwxyz'), '{t}')]",
        f"//a[contains(translate(normalize-space(.),'ABCDEFGHIJKLMNOPQRSTUVWXYZ','abcdefghijklmnopqrstuvwxyz'), '{t}')]",
        f"//button[contains(translate(normalize-space(.),'ABCDEFGHIJKLMNOPQRSTUVWXYZ','abcdefghijklmnopqrstuvwxyz'), '{t}')]",
    ]
    last_exc = None
    for xp in xpaths:
        try:
            el = WebDriverWait(driver, timeout).until(EC.element_to_be_clickable((By.XPATH, xp)))
            driver.execute_script("arguments[0].scrollIntoView({block:'center', inline:'nearest'});", el)
            time.sleep(SHORT_SLEEP)
            try:
                el.click()
            except Exception:
                driver.execute_script("arguments[0].click();", el)
            time.sleep(SHORT_SLEEP)
            step.snap(f"S_CLICKED_{text}", html=True)
            return el
        except Exception as e:
            last_exc = e
            continue
    raise Exception(f"click_element_by_text: could not click element by text '{text}'; last: {last_exc}")

def robust_click_target(element):
    """Try multiple click strategies on a WebElement."""
    try:
        element.click()
        return True
    except Exception:
        pass
    try:
        ActionChains(driver).move_to_element(element).click(element).perform()
        return True
    except Exception:
        pass
    try:
        driver.execute_script("arguments[0].scrollIntoView({block:'center', inline:'nearest'});", element)
        driver.execute_script("arguments[0].click();", element)
        return True
    except Exception:
        pass
    return False

# ---------------- ensure Configure clicked ----------------
def ensure_click_configure():
    """
    Robustly click the 'Configure' navigation item.
    Tries text click, aria/title, and falls back to candidate search.
    """
    step.snap("S_BEFORE_click_configure", html=True)
    wait_for_no_overlay(wait=8)
    # 1) try direct text
    try:
        click_element_by_text("configure", timeout=8)
        step.snap("S_AFTER_click_configure", html=True)
        return True
    except Exception as e:
        print("Direct click 'Configure' failed:", e)

    # 2) try known nav selectors (aria-label/title)
    try:
        xps = [
            "//*[contains(translate(@aria-label,'ABCDEFGHIJKLMNOPQRSTUVWXYZ','abcdefghijklmnopqrstuvwxyz'),'configure')]",
            "//*[contains(translate(@title,'ABCDEFGHIJKLMNOPQRSTUVWXYZ','abcdefghijklmnopqrstuvwxyz'),'configure')]",
            "//nav//*[contains(translate(normalize-space(.),'ABCDEFGHIJKLMNOPQRSTUVWXYZ','abcdefghijklmnopqrstuvwxyz'),'configure')]"
        ]
        for xp in xps:
            try:
                el = driver.find_element(By.XPATH, xp)
                if el and el.is_displayed():
                    if robust_click_target(el):
                        step.snap("S_AFTER_click_configure_alt", html=True)
                        return True
            except Exception:
                continue
    except Exception:
        pass

    # 3) candidate search: find visible elements that likely represent the left nav,
    #    then click the one that contains 'configure' text inside them.
    try:
        candidates = driver.find_elements(By.XPATH, "//*[contains(translate(normalize-space(.),'ABCDEFGHIJKLMNOPQRSTUVWXYZ','abcdefghijklmnopqrstuvwxyz'),'configure')]")
        for c in candidates:
            try:
                if not c.is_displayed():
                    continue
                if robust_click_target(c):
                    step.snap("S_AFTER_click_configure_fuzzy", html=True)
                    return True
            except Exception:
                continue
    except Exception:
        pass

    step.snap("S_ERR_click_configure", html=True)
    raise Exception("ensure_click_configure: unable to click 'Configure'")

# ---------------- ensure click AMF (category & left entry) ----------------
def ensure_select_amf():
    """
    Ensure 'AMF' category and left 'amf' entry are selected.
    We:
      - try clicking AMF category (top/main)
      - then robustly search for left panel entry labeled 'amf' and click it using many strategies
      - dump candidate outerHTML to debug file for troubleshooting if cannot find
    """
    step.snap("S_BEFORE_select_amf", html=True)
    wait_for_no_overlay(wait=8)
    # attempt category click (main area)
    try:
        click_element_by_text("amf", timeout=6)
        time.sleep(SHORT_SLEEP)
        step.snap("S_AFTER_click_amf_category", html=True)
    except Exception:
        # not fatal — proceed to robust left-panel selection
        print("Top AMF category click didn't work or not sufficient; continuing to left-panel selection.")

    # now robust left-side entry
    # gather candidates
    patterns = [
        "//*[translate(normalize-space(.),'ABCDEFGHIJKLMNOPQRSTUVWXYZ','abcdefghijklmnopqrstuvwxyz')='amf']",
        "//*[contains(translate(normalize-space(.),'ABCDEFGHIJKLMNOPQRSTUVWXYZ','abcdefghijklmnopqrstuvwxyz'),' amf ')]",
        "//nav//*[contains(translate(normalize-space(.),'ABCDEFGHIJKLMNOPQRSTUVWXYZ','abcdefghijklmnopqrstuvwxyz'),'amf')]",
        "//*[contains(@aria-label,'AMF') or contains(@aria-label,'amf')]",
        "//*[@title and contains(translate(@title,'ABCDEFGHIJKLMNOPQRSTUVWXYZ','abcdefghijklmnopqrstuvwxyz'),'amf')]",
        "//li[.//text()[contains(translate(. ,'ABCDEFGHIJKLMNOPQRSTUVWXYZ','abcdefghijklmnopqrstuvwxyz'),'amf')]]",
    ]
    candidates = []
    for xp in patterns:
        try:
            found = driver.find_elements(By.XPATH, xp)
            for f in found:
                if f not in candidates:
                    candidates.append(f)
        except Exception:
            pass

    # Dump candidate outerHTML for debugging
    try:
        dump_lines = []
        dump_lines.append(f"AMF candidates dump time={time.strftime('%Y-%m-%d %H:%M:%S')}\n")
        for i, el in enumerate(candidates[:50]):
            try:
                outer = driver.execute_script("return arguments[0].outerHTML;", el)
            except Exception:
                outer = "<outerHTML not available>"
            vis = False
            try:
                vis = el.is_displayed()
            except Exception:
                vis = False
            dump_lines.append(f"--- candidate {i} visible={vis} ---\n{outer}\n\n")
        dump_file = os.path.join(DEBUG_DIR, f"amf_candidates_{int(time.time())}.txt")
        with open(dump_file, "w", encoding="utf-8") as fh:
            fh.writelines(dump_lines)
        print("[DEBUG] candidate dump written:", dump_file)
        step.snap("S_AFTER_amf_candidates_dump", html=True)
    except Exception as e:
        print("Failed to write AMF candidate dump:", e)

    # Try preferred exact-text candidates first
    for el in list(candidates):
        try:
            try:
                txt = (el.text or "").strip()
            except Exception:
                txt = ""
            if txt and txt.lower() == "amf":
                driver.execute_script("arguments[0].scrollIntoView({block:'center'});", el)
                time.sleep(0.12)
                if robust_click_target(el):
                    step.snap("S_CLICK_amf_exact", html=True)
                    print("Clicked AMF exact candidate")
                    return True
        except Exception:
            continue

    # try child anchors / clickable children inside each candidate
    for el in list(candidates):
        try:
            # anchor child
            try:
                a = el.find_element(By.XPATH, ".//a[normalize-space(.)!='']")
                if a.is_displayed():
                    driver.execute_script("arguments[0].scrollIntoView({block:'center'});", a)
                    time.sleep(0.1)
                    if robust_click_target(a):
                        step.snap("S_CLICK_amf_child_a", html=True)
                        print("Clicked AMF via child <a>")
                        return True
            except Exception:
                pass
            # span child
            try:
                sp = el.find_element(By.XPATH, ".//span[normalize-space(.)!='']")
                if sp.is_displayed():
                    driver.execute_script("arguments[0].scrollIntoView({block:'center'});", sp)
                    time.sleep(0.1)
                    if robust_click_target(sp):
                        step.snap("S_CLICK_amf_child_span", html=True)
                        print("Clicked AMF via child <span>")
                        return True
            except Exception:
                pass
            # action chains on element
            driver.execute_script("arguments[0].scrollIntoView({block:'center'});", el)
            time.sleep(0.08)
            try:
                ActionChains(driver).move_to_element(el).pause(0.08).click(el).perform()
                step.snap("S_CLICK_amf_actionchains", html=True)
                print("Clicked AMF via ActionChains on candidate")
                return True
            except Exception:
                pass
            # js click fallback
            try:
                driver.execute_script("arguments[0].click();", el)
                step.snap("S_CLICK_amf_js", html=True)
                print("Clicked AMF via JS on candidate")
                return True
            except Exception:
                pass
        except Exception:
            continue

    # As last resort fuzzy search and click
    try:
        fuzzy = driver.find_elements(By.XPATH, "//*[contains(translate(normalize-space(.),'ABCDEFGHIJKLMNOPQRSTUVWXYZ','abcdefghijklmnopqrstuvwxyz'),'amf')]")
        for f in fuzzy:
            try:
                if not f.is_displayed():
                    continue
                driver.execute_script("arguments[0].scrollIntoView({block:'center'});", f)
                time.sleep(0.08)
                if robust_click_target(f):
                    step.snap("S_CLICK_amf_fuzzy", html=True)
                    print("Clicked AMF via fuzzy candidate")
                    return True
            except Exception:
                continue
    except Exception:
        pass

    step.snap("S_ERR_click_amf_final", html=True)
    raise Exception("ensure_select_amf: unable to click AMF after many retries")

# ---------------- file upload helper ----------------
def upload_config_file(file_path):
    step.snap("S_BEFORE_upload", html=True)
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
            step.snap("S_AFTER_upload_sendkeys", html=True)
            return True
        except Exception:
            pass

    # fallback inject
    try:
        uid = f"tmp_file_input_{int(time.time())}"
        js = "var i=document.createElement('input'); i.type='file'; i.id=arguments[0]; i.style.display='block'; document.body.appendChild(i); return i;"
        driver.execute_script(js, uid)
        tmp = driver.find_element(By.ID, uid)
        tmp.send_keys(file_path)
        time.sleep(SHORT_SLEEP)
        step.snap("S_AFTER_upload_injected", html=True)
        return True
    except Exception:
        step.snap("S_ERR_upload_no_input", html=True)
        raise Exception("upload_config_file: could not find or create file input")

# ---------------- import/apply helpers ----------------
def click_import():
    step.snap("S_BEFORE_import", html=True)
    texts = ["persist configurations", "persist", "import", "upload", "persist configuration", "save configuration"]
    for t in texts:
        try:
            btns = driver.find_elements(By.XPATH, f"//*[contains(translate(normalize-space(.),'ABCDEFGHIJKLMNOPQRSTUVWXYZ','abcdefghijklmnopqrstuvwxyz'), '{t}')]")
            btn = _first_visible(btns)
            if btn:
                if robust_click_target(btn):
                    time.sleep(MED_SLEEP)
                    step.snap("S_AFTER_import", html=True)
                    handle_native_alerts(timeout=6, accept=True)
                    return True
        except Exception:
            pass
    step.snap("S_ERR_import_not_found", html=True)
    raise Exception("click_import: import/persist button not found")

def click_apply():
    step.snap("S_BEFORE_apply", html=True)
    # scroll a small amount
    try:
        driver.execute_script("window.scrollBy(0, 300);")
    except Exception:
        pass
    time.sleep(SHORT_SLEEP)

    words = ["apply", "apply changes", "confirm", "ok", "yes"]
    for w in words:
        try:
            btns = driver.find_elements(By.XPATH, f"//*[contains(translate(normalize-space(.),'ABCDEFGHIJKLMNOPQRSTUVWXYZ','abcdefghijklmnopqrstuvwxyz'), '{w}')]")
            btn = _first_visible(btns)
            if btn:
                if robust_click_target(btn):
                    time.sleep(MED_SLEEP)
                    step.snap("S_AFTER_apply", html=True)
                    handle_native_alerts(timeout=6, accept=True)
                    return True
        except Exception:
            pass

    step.snap("S_ERR_apply_not_found", html=True)
    raise Exception("click_apply: apply/confirm button not found")

# ---------------- main flow ----------------
def main():
    try:
        print("Starting GUI upload run")
        driver.get(URL)
        step.snap("S_LOGIN_page_open", html=True)
        wait_document_ready(25)
        time.sleep(MED_SLEEP)

        # Login
        try:
            u = driver.find_element(By.XPATH, "//input[@type='text' or @type='email' or contains(translate(@name,'ABCDEFGHIJKLMNOPQRSTUVWXYZ','abcdefghijklmnopqrstuvwxyz'),'user')]")
            p = driver.find_element(By.XPATH, "//input[@type='password' or contains(translate(@name,'ABCDEFGHIJKLMNOPQRSTUVWXYZ','abcdefghijklmnopqrstuvwxyz'),'pass')]")
        except Exception:
            # broader search
            try:
                u = WebDriverWait(driver, 8).until(EC.presence_of_element_located((By.XPATH, "//input[@type='text' or @type='email']")))
                p = WebDriverWait(driver, 8).until(EC.presence_of_element_located((By.XPATH, "//input[@type='password']")))
            except Exception as ee:
                step.snap("S_ERR_login_fields_missing", html=True)
                raise Exception("Login fields not found") from ee

        u.clear(); u.send_keys(USERNAME)
        p.clear(); p.send_keys(PASSWORD)
        p.send_keys(Keys.RETURN)
        time.sleep(MED_SLEEP)
        step.snap("S_AFTER_login", html=True)
        wait_document_ready(20)
        time.sleep(MED_SLEEP)

        # Ensure Configure clicked
        try:
            ensure_click_configure()
        except Exception as e:
            print("ensure_click_configure failed:", e)
            step.snap("S_ERR_configure_click", html=True)
            raise

        time.sleep(SHORT_SLEEP)

        # Ensure AMF selected
        try:
            ensure_select_amf()
        except Exception as e:
            print("ensure_select_amf failed:", e)
            step.snap("S_ERR_amf_click", html=True)
            raise

        time.sleep(MED_SLEEP)
        step.snap("S_AFTER_amf_selected", html=True)

        # Upload files
        if not os.path.isdir(CONFIG_DIR):
            raise Exception(f"CONFIG_DIR '{CONFIG_DIR}' not found")

        files = sorted(os.listdir(CONFIG_DIR))
        for fname in files:
            if not fname.lower().endswith("_amf.json"):
                continue
            fpath = os.path.abspath(os.path.join(CONFIG_DIR, fname))
            print("Processing:", fpath)
            step.snap(f"S_START_upload_{fname}", html=True)

            upload_config_file(fpath)
            click_import()

            # scroll towards bottom to make Apply visible and click
            try:
                driver.execute_script("window.scrollTo(0, document.body.scrollHeight - 200);")
            except Exception:
                pass
            time.sleep(SHORT_SLEEP)

            click_apply()

            # click Ok if visible
            try:
                okbtns = driver.find_elements(By.XPATH, "//*[contains(translate(normalize-space(.),'ABCDEFGHIJKLMNOPQRSTUVWXYZ','abcdefghijklmnopqrstuvwxyz'),'ok') and (self::button or self::a)]")
                okbtn = _first_visible(okbtns)
                if okbtn:
                    robust_click_target(okbtn)
                    time.sleep(SHORT_SLEEP)
                    step.snap("S_AFTER_ok_click", html=True)
            except Exception:
                pass

            # wait for success toast
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
                print("Upload success detected for:", fname)
            else:
                print("No explicit success toast for:", fname)
            step.snap(f"S_DONE_upload_{fname}", html=True)

        print("All AMF uploads processed.")
    except Exception as e:
        print("Main flow error:", e)
        traceback.print_exc()
        step.snap("S_ERR_main_exception", html=True)
    finally:
        try:
            time.sleep(0.8)
            driver.quit()
        except Exception:
            pass

if __name__ == "__main__":
    main()
