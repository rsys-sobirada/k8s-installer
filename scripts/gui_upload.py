#!/usr/bin/env python3
"""
gui_upload.py - AMF uploader with robust Apply + confirmation handling.

Flow:
  - Login
  - Configure -> AMF -> amf
  - Choose File -> Import
  - APPLY (robust) -> Confirmation modal -> click OK
  - Repeat for files in config_files

Saves screenshots and HTML to debug_screenshots/ for Jenkins artifacting.
Set HEADLESS=0 to run with visible browser while debugging.
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
        "//*[contains(@class,'overlay') or contains(@class,'backdrop') or contains(@class,'modal-backdrop') or contains(@class,'cdk-overlay-backdrop') or contains(@class,'MuiBackdrop-root')]",
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

def robust_click(elem):
    """Try click, ActionChains, JS click in order."""
    try:
        elem.click()
        return True
    except Exception:
        pass
    try:
        ActionChains(driver).move_to_element(elem).pause(0.1).click(elem).perform()
        return True
    except Exception:
        pass
    try:
        driver.execute_script("arguments[0].scrollIntoView({block:'center'});", elem)
        driver.execute_script("arguments[0].click();", elem)
        return True
    except Exception:
        pass
    return False

# ---------------- Navigation helpers (Configure / AMF / amf) ----------------
def open_configure_menu():
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
            el = _first_visible(elems)
            if not el:
                continue
            try:
                el.click()
            except Exception:
                try:
                    driver.execute_script("arguments[0].click();", el)
                except Exception as js_e:
                    last_err = js_e
            time.sleep(MED_SLEEP)
            step.snap("S_CLICKED_configure", html=True)
            return True
        except Exception as e:
            last_err = e
            continue
    step.snap("S_ERR_click_configure", html=True)
    raise Exception(f"open_configure_menu: unable to click Configure; last_err={last_err}")

def open_nf_menu(name):
    step.snap(f"S_BEFORE_open_nf_{name}", html=True)
    wait_for_no_overlay(wait=8)
    t = name.lower()
    candidate_xps = [
        f"//nav//a//*[contains(translate(normalize-space(.),'ABCDEFGHIJKLMNOPQRSTUVWXYZ','abcdefghijklmnopqrstuvwxyz'),'{t}')]",
        f"//a[contains(translate(normalize-space(.),'ABCDEFGHIJKLMNOPQRSTUVWXYZ','abcdefghijklmnopqrstuvwxyz'),'{t}')]",
        f"//*[contains(translate(normalize-space(.),'ABCDEFGHIJKLMNOPQRSTUVWXYZ','abcdefghijklmnopqrstuvwxyz'),'{t}')]",
    ]
    last_err = None
    for xp in candidate_xps:
        try:
            elems = driver.find_elements(By.XPATH, xp)
            el = _first_visible(elems)
            if el:
                try:
                    el.click()
                except Exception:
                    driver.execute_script("arguments[0].click();", el)
                time.sleep(MED_SLEEP)
                step.snap(f"S_CLICKED_nf_{name}", html=True)
                return el
        except Exception as e:
            last_err = e
            continue
    step.snap(f"S_ERR_click_nf_{name}", html=True)
    raise Exception(f"open_nf_menu: unable to click NF '{name}'; last_err={last_err}")

def click_amf_subentry():
    """
    Click the 'amf' sub-entry inside the AMF panel. Uses robust strategies.
    """
    step.snap("S_BEFORE_click_amf_subentry", html=True)
    wait_for_no_overlay(wait=8)
    time.sleep(SHORT_SLEEP)

    # search inside visible panels for exact 'amf' nodes
    candidates = []
    try:
        panels = driver.find_elements(By.XPATH, "//*[contains(translate(@class,'ABCDEFGHIJKLMNOPQRSTUVWXYZ','abcdefghijklmnopqrstuvwxyz'),'panel') or contains(translate(@class,'ABCDEFGHIJKLMNOPQRSTUVWXYZ','abcdefghijklmnopqrstuvwxyz'),'content') or contains(translate(@id,'ABCDEFGHIJKLMNOPQRSTUVWXYZ','abcdefghijklmnopqrstuvwxyz'),'amf') or contains(translate(@id,'ABCDEFGHIJKLMNOPQRSTUVWXYZ','abcdefghijklmnopqrstuvwxyz'),'AMF')]")
        panels = [p for p in panels if p.is_displayed()]
    except Exception:
        panels = []

    contexts = panels if panels else [driver]
    for ctx in contexts:
        try:
            exacts = ctx.find_elements(By.XPATH, ".//*[translate(normalize-space(.),'ABCDEFGHIJKLMNOPQRSTUVWXYZ','abcdefghijklmnopqrstuvwxyz')='amf']")
            for e in exacts:
                if e not in candidates:
                    candidates.append(e)
            anchors = ctx.find_elements(By.XPATH, ".//a[contains(translate(normalize-space(.),'ABCDEFGHIJKLMNOPQRSTUVWXYZ','abcdefghijklmnopqrstuvwxyz'),'amf')]")
            for a in anchors:
                if a not in candidates:
                    candidates.append(a)
            lis = ctx.find_elements(By.XPATH, ".//li[contains(translate(normalize-space(.),'ABCDEFGHIJKLMNOPQRSTUVWXYZ','abcdefghijklmnopqrstuvwxyz'),'amf')]")
            for li in lis:
                if li not in candidates:
                    candidates.append(li)
        except Exception:
            continue

    # final fuzzy if empty
    if not candidates:
        try:
            fuzzy = driver.find_elements(By.XPATH, "//*[contains(translate(normalize-space(.),'ABCDEFGHIJKLMNOPQRSTUVWXYZ','abcdefghijklmnopqrstuvwxyz'),'amf')]")
            for f in fuzzy:
                if f not in candidates:
                    candidates.append(f)
        except Exception:
            pass

    # dump candidate outerHTML for debugging
    try:
        dump = []
        for i, c in enumerate(candidates[:200]):
            try:
                outer = driver.execute_script("return arguments[0].outerHTML;", c)
            except Exception:
                outer = "<outerHTML unavailable>"
            vis = False
            try:
                vis = c.is_displayed()
            except Exception:
                vis = False
            dump.append(f"--- cand {i} visible={vis} ---\n{outer}\n\n")
        dump_file = os.path.join(DEBUG_DIR, f"amf_subentry_candidates_{int(time.time())}.txt")
        with open(dump_file, "w", encoding="utf-8") as fh:
            fh.writelines(dump)
        print("[DEBUG] wrote amf_subentry candidate dump:", dump_file)
        step.snap("S_AFTER_amf_subentry_candidates_dump", html=True)
    except Exception:
        pass

    for el in candidates:
        try:
            if not el.is_displayed():
                continue
            try:
                el.click()
            except Exception:
                try:
                    ActionChains(driver).move_to_element(el).click(el).perform()
                except Exception:
                    try:
                        driver.execute_script("arguments[0].scrollIntoView({block:'center'});", el)
                        driver.execute_script("arguments[0].click();", el)
                    except Exception:
                        pass
            step.snap("S_AFTER_click_amf_subentry", html=True)
            return True
        except Exception:
            continue
    step.snap("S_ERR_click_amf_subentry", html=True)
    raise Exception("click_amf_subentry: could not click 'amf' sub-entry; check amf_subentry_candidates_*.txt")

# ---------------- File upload helpers (unchanged) ----------------
def upload_config_file(file_path):
    step.snap("S_BEFORE_upload", html=True)
    selectors = ["//input[@type='file']", "//input[contains(@class,'file') and @type='file']", "//input[contains(@id,'file') and @type='file']"]
    for sel in selectors:
        try:
            inp = driver.find_element(By.XPATH, sel)
            driver.execute_script("arguments[0].style.display='block'; arguments[0].style.visibility='visible';", inp)
            inp.send_keys(file_path)
            time.sleep(SHORT_SLEEP)
            step.snap("S_AFTER_upload_sendkeys", html=True)
            return True
        except Exception:
            continue
    # fallback injection
    try:
        uid = f"tmp_file_{int(time.time())}"
        driver.execute_script("var i=document.createElement('input'); i.type='file'; i.id=arguments[0]; i.style.display='block'; document.body.appendChild(i); return i;", uid)
        tmp = driver.find_element(By.ID, uid)
        tmp.send_keys(file_path)
        time.sleep(SHORT_SLEEP)
        step.snap("S_AFTER_upload_injected", html=True)
        return True
    except Exception:
        step.snap("S_ERR_upload_no_input", html=True)
        raise Exception("upload_config_file: could not find or inject file input")

def click_import():
    step.snap("S_BEFORE_import", html=True)
    texts = ["persist configurations", "persist", "import", "upload", "persist configuration", "save configuration"]
    for t in texts:
        try:
            nodes = driver.find_elements(By.XPATH, f"//*[contains(translate(normalize-space(.),'ABCDEFGHIJKLMNOPQRSTUVWXYZ','abcdefghijklmnopqrstuvwxyz'), '{t}')]")
            btn = _first_visible(nodes)
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
    raise Exception("click_import: import/persist not found")

# ---------------- NEW: Apply + confirmation routine ----------------
def apply_and_confirm(retries=2):
    """
    Click Apply and then click OK on the confirmation popup/modal.
    Retries a small number of times if the Apply or Ok button is not found.
    """
    step.snap("S_BEFORE_apply_and_confirm", html=True)
    last_err = None
    for attempt in range(1, retries + 1):
        print(f"apply_and_confirm: attempt {attempt}/{retries}")
        try:
            # 1) ensure overlays gone
            wait_for_no_overlay(wait=8)
            time.sleep(SHORT_SLEEP)

            # 2) try to find an 'Apply' button in footers, modals, or page
            apply_xps = [
                "//*[self::button or self::a or self::span or self::div][contains(translate(normalize-space(.),'ABCDEFGHIJKLMNOPQRSTUVWXYZ','abcdefghijklmnopqrstuvwxyz'),'apply')]",
                "//*[self::button or self::a][contains(translate(normalize-space(.),'ABCDEFGHIJKLMNOPQRSTUVWXYZ','abcdefghijklmnopqrstuvwxyz'),'apply changes')]",
                "//*[contains(@class,'apply') and (self::button or self::a or self::div)]",
                # common modal footer candidate
                "//*[contains(translate(normalize-space(.),'ABCDEFGHIJKLMNOPQRSTUVWXYZ','abcdefghijklmnopqrstuvwxyz'),'confirm') and (self::button or self::a)]",
            ]
            apply_btn = None
            for xp in apply_xps:
                try:
                    nodes = driver.find_elements(By.XPATH, xp)
                    apply_btn = _first_visible(nodes)
                    if apply_btn:
                        break
                except Exception:
                    continue

            # 3) if not found, try searching modal footers
            if not apply_btn:
                try:
                    footers = driver.find_elements(By.XPATH, "//*[contains(@class,'modal') or contains(@class,'dialog') or contains(@class,'footer') or contains(@class,'button-bar')]")
                    for f in footers:
                        try:
                            cand = f.find_elements(By.XPATH, ".//*[contains(translate(normalize-space(.),'ABCDEFGHIJKLMNOPQRSTUVWXYZ','abcdefghijklmnopqrstuvwxyz'),'apply') or contains(translate(normalize-space(.),'ABCDEFGHIJKLMNOPQRSTUVWXYZ','abcdefghijklmnopqrstuvwxyz'),'confirm') or contains(translate(normalize-space(.),'ABCDEFGHIJKLMNOPQRSTUVWXYZ','abcdefghijklmnopqrstuvwxyz'),'ok')]")
                            btn = _first_visible(cand)
                            if btn:
                                apply_btn = btn
                                break
                        except Exception:
                            continue
                except Exception:
                    pass

            # 4) Last resort: search entire page for visible 'apply' text
            if not apply_btn:
                try:
                    candidates = driver.find_elements(By.XPATH, "//*[contains(translate(normalize-space(.),'ABCDEFGHIJKLMNOPQRSTUVWXYZ','abcdefghijklmnopqrstuvwxyz'),'apply')]")
                    apply_btn = _first_visible(candidates)
                except Exception:
                    apply_btn = None

            if not apply_btn:
                raise Exception("Apply button not found on attempt " + str(attempt))

            # 5) Click Apply (robustly)
            try:
                apply_btn_location_text = (apply_btn.text or "")[:80]
                print("Found Apply button text:", apply_btn_location_text)
            except Exception:
                pass
            try:
                apply_btn.click()
            except Exception:
                try:
                    ActionChains(driver).move_to_element(apply_btn).click(apply_btn).perform()
                except Exception:
                    driver.execute_script("arguments[0].scrollIntoView({block:'center'}); arguments[0].click();", apply_btn)
            step.snap(f"S_AFTER_click_apply_attempt{attempt}", html=True)

            # 6) Wait for modal/confirmation to appear (either native alert or JS modal)
            # Check native alert first
            native_text = handle_native_alerts(timeout=4, accept=False)
            if native_text:
                print("Native confirmation detected:", native_text)
                # accept it explicitly now
                handle_native_alerts(timeout=2, accept=True)
                step.snap("S_AFTER_native_alert_accepted", html=True)
                return True

            # Wait for an OK/Confirm button in a modal/dialog
            ok_xps = [
                "//button[contains(translate(normalize-space(.),'ABCDEFGHIJKLMNOPQRSTUVWXYZ','abcdefghijklmnopqrstuvwxyz'),'ok')]",
                "//button[contains(translate(normalize-space(.),'ABCDEFGHIJKLMNOPQRSTUVWXYZ','abcdefghijklmnopqrstuvwxyz'),'yes')]",
                "//button[contains(translate(normalize-space(.),'ABCDEFGHIJKLMNOPQRSTUVWXYZ','abcdefghijklmnopqrstuvwxyz'),'confirm')]",
                "//*[self::a or self::span or self::div][contains(translate(normalize-space(.),'ABCDEFGHIJKLMNOPQRSTUVWXYZ','abcdefghijklmnopqrstuvwxyz'),'ok')]",
            ]

            ok_btn = None
            # Give modal a few seconds to appear
            modal_wait_end = time.time() + 6
            while time.time() < modal_wait_end and not ok_btn:
                for xp in ok_xps:
                    try:
                        nodes = driver.find_elements(By.XPATH, xp)
                        ok_btn = _first_visible(nodes)
                        if ok_btn:
                            break
                    except Exception:
                        continue
                if not ok_btn:
                    time.sleep(0.3)

            if ok_btn:
                try:
                    ok_text = (ok_btn.text or "")[:80]
                    print("Found OK button with text:", ok_text)
                except Exception:
                    pass
                try:
                    ok_btn.click()
                except Exception:
                    try:
                        ActionChains(driver).move_to_element(ok_btn).click(ok_btn).perform()
                    except Exception:
                        driver.execute_script("arguments[0].scrollIntoView({block:'center'}); arguments[0].click();", ok_btn)
                step.snap(f"S_AFTER_click_ok_attempt{attempt}", html=True)
                # allow UI to process
                time.sleep(MED_SLEEP)
                # also clear any native alert if present
                handle_native_alerts(timeout=2, accept=True)
                return True

            # if reached here, no native alert and no OK button found; could be delay, try again
            print("Apply clicked but no confirmation modal/OK found yet; retrying after short wait")
            time.sleep(1.0)
        except Exception as e:
            last_err = e
            print("apply_and_confirm attempt error:", e)
            step.snap(f"S_ERR_apply_attempt{attempt}", html=True)
            time.sleep(0.8)
            continue

    # all retries exhausted
    step.snap("S_ERR_apply_all_retries_failed", html=True)
    raise Exception("apply_and_confirm: failed to click Apply and confirm; last_err=" + str(last_err))

# ---------------- helper: click_apply (thin wrapper) ----------------
def click_apply():
    return apply_and_confirm(retries=3)

# ---------------- Main flow (login, navigate, upload) ----------------
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
            u = WebDriverWait(driver, 8).until(EC.presence_of_element_located((By.XPATH, "//input[@type='text' or @type='email']")))
            p = WebDriverWait(driver, 8).until(EC.presence_of_element_located((By.XPATH, "//input[@type='password']")))
        u.clear(); u.send_keys(USERNAME)
        p.clear(); p.send_keys(PASSWORD)
        p.send_keys(Keys.RETURN)
        time.sleep(MED_SLEEP)
        step.snap("S_AFTER_login", html=True)
        wait_document_ready(20)
        time.sleep(MED_SLEEP)

        # Click Configure
        open_configure_menu()
        time.sleep(SHORT_SLEEP)

        # Click AMF
        open_nf_menu("AMF")
        time.sleep(SHORT_SLEEP)

        # Click amf sub-entry (the NF instance)
        try:
            # If you already have click_amf_subentry() in your script, call that.
            # Here we attempt a direct in-panel click for 'amf' text (fallback robust)
            step.snap("S_BEFORE_click_amf_subentry_main", html=True)
            # find element with exact 'amf' text and click
            el = None
            try:
                el = _first_visible(driver.find_elements(By.XPATH, "//*[translate(normalize-space(.),'ABCDEFGHIJKLMNOPQRSTUVWXYZ','abcdefghijklmnopqrstuvwxyz')='amf']"))
            except Exception:
                el = None
            if not el:
                # try contains
                el = _first_visible(driver.find_elements(By.XPATH, "//*[contains(translate(normalize-space(.),'ABCDEFGHIJKLMNOPQRSTUVWXYZ','abcdefghijklmnopqrstuvwxyz'),'amf')]"))
            if not el:
                raise Exception("amf entry not found")
            try:
                el.click()
            except Exception:
                try:
                    ActionChains(driver).move_to_element(el).click(el).perform()
                except Exception:
                    driver.execute_script("arguments[0].click();", el)
            step.snap("S_AFTER_click_amf_entry", html=True)
            time.sleep(MED_SLEEP)
        except Exception as e:
            print("clicking amf entry failed:", e)
            step.snap("S_ERR_click_amf_entry", html=True)
            raise

        # Wait for AMF panel readiness (file input / import visible)
        # Simple heuristic: presence of input[type=file] or "import" button
        amf_ready = False
        for _ in range(18):
            try:
                if driver.find_elements(By.XPATH, "//input[@type='file']"):
                    amf_ready = True
                    break
                if driver.find_elements(By.XPATH, "//*[contains(translate(normalize-space(.),'ABCDEFGHIJKLMNOPQRSTUVWXYZ','abcdefghijklmnopqrstuvwxyz'),'import')]"):
                    amf_ready = True
                    break
            except Exception:
                pass
            time.sleep(0.5)
        step.snap("S_AFTER_amf_panel_ready", html=True)
        if not amf_ready:
            print("Warning: AMF panel not obviously ready; continuing anyway (check screenshots)")

        # Process files
        if not os.path.isdir(CONFIG_DIR):
            raise Exception(f"CONFIG_DIR '{CONFIG_DIR}' not found")
        files = sorted(os.listdir(CONFIG_DIR))
        for fname in files:
            if not fname.lower().endswith("_amf.json"):
                continue
            fpath = os.path.abspath(os.path.join(CONFIG_DIR, fname))
            print("Processing:", fpath)
            step.snap(f"S_START_upload_{fname}", html=True)

            # Choose file (upload)
            uploaded = upload_config_file(fpath)
            if not uploaded:
                raise Exception("Failed to upload file " + fname)

            # Import / Persist
            click_import()

            # Now Apply and click OK on confirmation
            click_apply()

            # After confirmation, wait briefly and take a snapshot
            time.sleep(MED_SLEEP)
            step.snap(f"S_AFTER_apply_and_confirm_{fname}", html=True)

            # optional: final ok press in page modals (defensive)
            try:
                okbtn = _first_visible(driver.find_elements(By.XPATH, "//button[contains(translate(normalize-space(.),'ABCDEFGHIJKLMNOPQRSTUVWXYZ','abcdefghijklmnopqrstuvwxyz'),'ok') or //a[contains(translate(normalize-space(.),'ABCDEFGHIJKLMNOPQRSTUVWXYZ','abcdefghijklmnopqrstuvwxyz'),'ok')]]"))
                if okbtn:
                    try:
                        okbtn.click()
                    except Exception:
                        driver.execute_script("arguments[0].click();", okbtn)
                    time.sleep(SHORT_SLEEP)
                    step.snap(f"S_EXTRA_ok_click_{fname}", html=True)
            except Exception:
                pass

            # wait for success toast (best-effort)
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
