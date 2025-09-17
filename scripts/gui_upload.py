#!/usr/bin/env python3
"""
gui_upload.py - Use original Configure click logic + robust AMF selection.

Flow:
 - Login
 - open_configure_menu()  <- uses conservative original logic to click Configure
 - click_nf_tab("AMF")    <- clicks the AMF category
 - ensure_select_amf()    <- robust left-panel 'amf' click (many fallbacks)
 - Choose file -> Import -> scroll -> Apply -> Ok
Saves debug screenshots and HTML under debug_screenshots/
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

# ---------------- CONFIG ----------------
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

# ---------------- Original-style Configure click (restored) ----------------
def open_configure_menu():
    """
    Conservative logic to click the 'Configure' navigation item.
    Mirrors original script's multi-xpath approach and JS fallback.
    """
    step.snap("S_BEFORE_click_configure", html=True)
    wait_for_no_overlay(wait=8)

    candidate_xps = [
        "//nav//a//*[contains(translate(normalize-space(.),'ABCDEFGHIJKLMNOPQRSTUVWXYZ','abcdefghijklmnopqrstuvwxyz'),'configure')]",
        "//a[contains(translate(normalize-space(.),'ABCDEFGHIJKLMNOPQRSTUVWXYZ','abcdefghijklmnopqrstuvwxyz'),'configure')]",
        "//*[contains(translate(normalize-space(.),'ABCDEFGHIJKLMNOPQRSTUVWXYZ','abcdefghijklmnopqrstuvwxyz'),'configure')]",
        "//*[@aria-label and contains(translate(@aria-label,'ABCDEFGHIJKLMNOPQRSTUVWXYZ','abcdefghijklmnopqrstuvwxyz'), 'configure')]",
        "//*[@title and contains(translate(@title,'ABCDEFGHIJKLMNOPQRSTUVWXYZ','abcdefghijklmnopqrstuvwxyz'), 'configure')]",
    ]

    last_err = None
    for xp in candidate_xps:
        try:
            elems = driver.find_elements(By.XPATH, xp)
            elem = _first_visible(elems)
            if not elem:
                continue
            try:
                elem.click()
            except Exception:
                try:
                    driver.execute_script("arguments[0].click();", elem)
                except Exception as js_e:
                    last_err = js_e
            time.sleep(MED_SLEEP)
            step.snap("S_CLICKED_configure", html=True)
            # verify Configure panel open by checking presence of left menu or AMF entry
            # wait a short while for panel to render
            time.sleep(0.6)
            return True
        except Exception as e:
            last_err = e
            continue

    # fallback: try to find configure text anywhere and click first visible
    try:
        el = _first_visible(driver.find_elements(By.XPATH, "//*[contains(translate(normalize-space(.),'ABCDEFGHIJKLMNOPQRSTUVWXYZ','abcdefghijklmnopqrstuvwxyz'),'configure')]"))
        if el:
            try:
                el.click()
            except Exception:
                driver.execute_script("arguments[0].click();", el)
            time.sleep(MED_SLEEP)
            step.snap("S_CLICKED_configure_fallback", html=True)
            return True
    except Exception:
        pass

    step.snap("S_ERR_click_configure", html=True)
    raise Exception(f"open_configure_menu: unable to click Configure (last_err={last_err})")

# ---------------- Click NF tab (original-style) ----------------
def click_nf_tab(nf_name):
    """
    Click the NF category tab (AMF/SMF/etc) using text match (original logic restored).
    """
    step.snap(f"S_BEFORE_click_nf_{nf_name}", html=True)
    wait_for_no_overlay(wait=8)
    t = nf_name.lower()
    xpaths = [
        f"//*[contains(translate(normalize-space(.),'ABCDEFGHIJKLMNOPQRSTUVWXYZ','abcdefghijklmnopqrstuvwxyz'), '{t}')]",
        f"//a[contains(translate(normalize-space(.),'ABCDEFGHIJKLMNOPQRSTUVWXYZ','abcdefghijklmnopqrstuvwxyz'), '{t}')]",
        f"//button[contains(translate(normalize-space(.),'ABCDEFGHIJKLMNOPQRSTUVWXYZ','abcdefghijklmnopqrstuvwxyz'), '{t}')]"
    ]
    last_err = None
    for xp in xpaths:
        try:
            elems = driver.find_elements(By.XPATH, xp)
            elem = _first_visible(elems)
            if elem:
                try:
                    elem.click()
                except Exception:
                    driver.execute_script("arguments[0].click();", elem)
                time.sleep(SHORT_SLEEP)
                step.snap(f"S_AFTER_click_nf_{nf_name}", html=True)
                return elem
        except Exception as e:
            last_err = e
            continue
    step.snap("S_ERR_click_nf_tab", html=True)
    raise Exception(f"click_nf_tab: could not click NF '{nf_name}'; last_err={last_err}")

# ---------------- Robust left-panel AMF selection ----------------
def ensure_select_amf():
    """
    Robustly select the left-panel 'amf' entry after Configure -> AMF category.
    Dumps candidates and tries many click strategies.
    """
    step.snap("S_BEFORE_select_amf", html=True)
    wait_for_no_overlay(wait=10)
    time.sleep(SHORT_SLEEP)

    # Try clicking top/main AMF category first (non-fatal)
    try:
        click_nf_tab("AMF")
        time.sleep(SHORT_SLEEP)
    except Exception:
        # will continue to robust left-panel logic
        pass

    # Collect candidate elements containing 'amf'
    xpath_patterns = [
        "//*[translate(normalize-space(.),'ABCDEFGHIJKLMNOPQRSTUVWXYZ','abcdefghijklmnopqrstuvwxyz')='amf']",
        "//*[contains(translate(normalize-space(.),'ABCDEFGHIJKLMNOPQRSTUVWXYZ','abcdefghijklmnopqrstuvwxyz'),' amf ')]",
        "//nav//*[contains(translate(normalize-space(.),'ABCDEFGHIJKLMNOPQRSTUVWXYZ','abcdefghijklmnopqrstuvwxyz'),'amf')]",
        "//*[contains(@aria-label,'AMF') or contains(@aria-label,'amf')]",
        "//*[@title and contains(translate(@title,'ABCDEFGHIJKLMNOPQRSTUVWXYZ','abcdefghijklmnopqrstuvwxyz'),'amf')]",
        "//li[.//text()[contains(translate(. ,'ABCDEFGHIJKLMNOPQRSTUVWXYZ','abcdefghijklmnopqrstuvwxyz'),'amf')]]",
    ]

    candidates = []
    for xp in xpath_patterns:
        try:
            found = driver.find_elements(By.XPATH, xp)
            for f in found:
                if f not in candidates:
                    candidates.append(f)
        except Exception:
            continue

    # Dump candidate outerHTML to debug file
    try:
        dump_lines = []
        dump_lines.append(f"AMF candidates dump time={time.strftime('%Y-%m-%d %H:%M:%S')}\n")
        for i, el in enumerate(candidates[:100]):
            try:
                outer = driver.execute_script("return arguments[0].outerHTML;", el)
            except Exception:
                outer = "<outerHTML unavailable>"
            vis = False
            try:
                vis = el.is_displayed()
            except Exception:
                vis = False
            dump_lines.append(f"--- candidate {i} visible={vis} ---\n{outer}\n\n")
        dump_file = os.path.join(DEBUG_DIR, f"amf_candidates_{int(time.time())}.txt")
        with open(dump_file, "w", encoding="utf-8") as fh:
            fh.writelines(dump_lines)
        print("[DEBUG] wrote candidate dump:", dump_file)
        step.snap("S_AFTER_amf_candidates_dump", html=True)
    except Exception as e:
        print("Failed to dump AMF candidates:", e)

    # prioritize exact-text matches
    for el in candidates:
        try:
            txt = (el.text or "").strip()
            if txt and txt.lower() == "amf":
                try:
                    driver.execute_script("arguments[0].scrollIntoView({block:'center'});", el)
                except Exception:
                    pass
                time.sleep(0.1)
                try:
                    el.click()
                except Exception:
                    try:
                        driver.execute_script("arguments[0].click();", el)
                    except Exception:
                        pass
                step.snap("S_CLICK_amf_exact", html=True)
                print("Clicked AMF exact candidate")
                return True
        except Exception:
            continue

    # try clicking child anchors/spans or JS/actionchains
    for el in candidates:
        try:
            try:
                a = el.find_element(By.XPATH, ".//a[normalize-space(.)!='']")
                if a.is_displayed():
                    try:
                        a.click()
                    except Exception:
                        driver.execute_script("arguments[0].click();", a)
                    step.snap("S_CLICK_amf_child_a", html=True)
                    print("Clicked child <a> in candidate")
                    return True
            except Exception:
                pass

            try:
                sp = el.find_element(By.XPATH, ".//span[normalize-space(.)!='']")
                if sp.is_displayed():
                    try:
                        sp.click()
                    except Exception:
                        driver.execute_script("arguments[0].click();", sp)
                    step.snap("S_CLICK_amf_child_span", html=True)
                    print("Clicked child <span> in candidate")
                    return True
            except Exception:
                pass

            # try action chains
            try:
                ActionChains(driver).move_to_element(el).pause(0.08).click(el).perform()
                step.snap("S_CLICK_amf_actionchains", html=True)
                print("Clicked candidate via ActionChains")
                return True
            except Exception:
                pass

            # js click fallback
            try:
                driver.execute_script("arguments[0].click();", el)
                step.snap("S_CLICK_amf_js", html=True)
                print("Clicked candidate via JS")
                return True
            except Exception:
                pass
        except Exception:
            continue

    # fuzzy last resort
    try:
        fuzzy = driver.find_elements(By.XPATH, "//*[contains(translate(normalize-space(.),'ABCDEFGHIJKLMNOPQRSTUVWXYZ','abcdefghijklmnopqrstuvwxyz'),'amf')]")
        for f in fuzzy:
            try:
                if not f.is_displayed():
                    continue
                try:
                    f.click()
                except Exception:
                    driver.execute_script("arguments[0].click();", f)
                step.snap("S_CLICK_amf_fuzzy", html=True)
                print("Clicked fuzzy element containing 'amf'")
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

    # fallback injection
    try:
        uid = f"tmp_upload_{int(time.time())}"
        js = "var inp=document.createElement('input'); inp.type='file'; inp.id=arguments[0]; inp.style.display='block'; document.body.appendChild(inp); return inp;"
        driver.execute_script(js, uid)
        tmp = driver.find_element(By.ID, uid)
        tmp.send_keys(file_path)
        time.sleep(SHORT_SLEEP)
        step.snap("S_AFTER_upload_injected", html=True)
        return True
    except Exception:
        step.snap("S_ERR_upload_no_input", html=True)
        raise Exception("upload_config_file: cannot locate or inject file input")

# ---------------- import / apply helpers ----------------
def click_import():
    step.snap("S_BEFORE_import", html=True)
    texts = ["persist configurations", "persist", "import", "upload", "persist configuration", "save configuration"]
    for t in texts:
        try:
            btns = driver.find_elements(By.XPATH, f"//*[contains(translate(normalize-space(.),'ABCDEFGHIJKLMNOPQRSTUVWXYZ','abcdefghijklmnopqrstuvwxyz'), '{t}')]")
            btn = _first_visible(btns)
            if btn:
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
    raise Exception("click_apply: apply/confirm button not found")

# ---------------- Main flow ----------------
def main():
    try:
        print("Starting GUI upload run")
        driver.get(URL)
        step.snap("S_LOGIN_page_open", html=True)
        wait_document_ready(25)
        time.sleep(MED_SLEEP)

        # Login fields
        try:
            u = driver.find_element(By.XPATH, "//input[@type='text' or @type='email' or contains(translate(@name,'ABCDEFGHIJKLMNOPQRSTUVWXYZ','abcdefghijklmnopqrstuvwxyz'),'user')]")
            p = driver.find_element(By.XPATH, "//input[@type='password' or contains(translate(@name,'ABCDEFGHIJKLMNOPQRSTUVWXYZ','abcdefghijklmnopqrstuvwxyz'),'pass')]")
        except Exception:
            u = WebDriverWait(driver, 8).until(EC.presence_of_element_located((By.XPATH, "//input[@type='text' or @type='email']")))
            p = WebDriverWait(driver, 8).until(EC.presence_of_element_located((By.XPATH, "//input[@type='password']")))

        u.clear(); u.send_keys(USERNAME)
        p.clear(); p.send_keys(PASSWORD)
        p.send_keys(Keys.RETURN)
        time.sleep(MED_SLEEP)
        step.snap("S_AFTER_login", html=True)
        wait_document_ready(20)
        time.sleep(MED_SLEEP)

        # Open Configure (use original restored logic)
        try:
            open_configure_menu()
        except Exception as e:
            print("open_configure_menu failed:", e)
            step.snap("S_ERR_configure_click", html=True)
            raise

        time.sleep(SHORT_SLEEP)

        # Attempt to select AMF
        try:
            ensure_select_amf()
        except Exception as e:
            print("ensure_select_amf failed:", e)
            step.snap("S_ERR_amf_click", html=True)
            raise

        time.sleep(MED_SLEEP)
        step.snap("S_AFTER_amf_selected", html=True)

        # Upload AMF files
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

            try:
                driver.execute_script("window.scrollTo(0, document.body.scrollHeight - 200);")
            except Exception:
                pass
            time.sleep(SHORT_SLEEP)

            click_apply()

            # click Ok if appears
            try:
                okbtns = driver.find_elements(By.XPATH, "//*[contains(translate(normalize-space(.),'ABCDEFGHIJKLMNOPQRSTUVWXYZ','abcdefghijklmnopqrstuvwxyz'),'ok') and (self::button or self::a)]")
                okbtn = _first_visible(okbtns)
                if okbtn:
                    try:
                        okbtn.click()
                    except Exception:
                        driver.execute_script("arguments[0].click();", okbtn)
                    time.sleep(SHORT_SLEEP)
                    step.snap("S_AFTER_ok_click", html=True)
            except Exception:
                pass

            # wait for toast success
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
                print("Upload success for:", fname)
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
