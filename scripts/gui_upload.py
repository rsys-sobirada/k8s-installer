#!/usr/bin/env python3
"""
gui_upload.py - Robust AMF uploader, now with explicit click for the 'amf' sub-entry
Flow:
  - Login
  - open_configure_menu()  (original-style)
  - open_nf_menu('AMF')    (original-style)
  - click_amf_subentry()   (new: click the 'amf' item inside AMF panel)
  - wait_for_amf_panel()
  - Choose File -> Import -> scroll -> Apply -> Ok
Saves debug screenshots/html into debug_screenshots/.
Set HEADLESS=0 for visible browser while debugging.
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

# ---------------- WebDriver ----------------
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
        return re.sub(r"[^0-9A-Za-z._-]+","_", str(s))[:80] or "step"
    def snap(self, label, html=False):
        self.counter += 1
        ts = int(time.time())
        name = f"{ts}_{self.counter:03d}_{self._clean(label)}"
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

# ---------------- Helpers ----------------
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

def _first_visible(elems):
    for e in elems:
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
        t = alert.text or ""
        print("Native alert:", t)
        if accept:
            alert.accept()
        else:
            alert.dismiss()
        time.sleep(SHORT_SLEEP)
        return t
    except TimeoutException:
        return ""
    except Exception as e:
        print("Alert handling error:", e)
        return ""

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

def robust_click_target(elem):
    """Try several click methods on an element."""
    try:
        if elem.is_displayed():
            try:
                elem.click()
                return True
            except Exception:
                pass
    except Exception:
        pass
    try:
        ActionChains(driver).move_to_element(elem).click(elem).perform()
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

# ---------------- Original-style Configure click (kept) ----------------
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
    # fallback
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
    raise Exception(f"open_configure_menu: unable to click Configure (last={last_err})")

# ---------------- Use same logic for NF menu (AMF) ----------------
def open_nf_menu(name):
    """
    Use same conservative logic as open_configure_menu but target nf 'name' (e.g. 'AMF').
    """
    step.snap(f"S_BEFORE_open_nf_{name}", html=True)
    wait_for_no_overlay(wait=8)
    t = name.lower()
    candidate_xps = [
        f"//nav//a//*[contains(translate(normalize-space(.),'ABCDEFGHIJKLMNOPQRSTUVWXYZ','abcdefghijklmnopqrstuvwxyz'),'{t}')]",
        f"//a[contains(translate(normalize-space(.),'ABCDEFGHIJKLMNOPQRSTUVWXYZ','abcdefghijklmnopqrstuvwxyz'),'{t}')]",
        f"//*[contains(translate(normalize-space(.),'ABCDEFGHIJKLMNOPQRSTUVWXYZ','abcdefghijklmnopqrstuvwxyz'),'{t}')]",
        f"//*[@aria-label and contains(translate(@aria-label,'ABCDEFGHIJKLMNOPQRSTUVWXYZ','abcdefghijklmnopqrstuvwxyz'), '{t}')]",
        f"//*[@title and contains(translate(@title,'ABCDEFGHIJKLMNOPQRSTUVWXYZ','abcdefghijklmnopqrstuvwxyz'), '{t}')]",
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
            step.snap(f"S_CLICKED_nf_{name}", html=True)
            return el
        except Exception as e:
            last_err = e
            continue
    # fallback
    try:
        el = _first_visible(driver.find_elements(By.XPATH, f"//*[contains(translate(normalize-space(.),'ABCDEFGHIJKLMNOPQRSTUVWXYZ','abcdefghijklmnopqrstuvwxyz'),'{t}')]"))
        if el:
            try:
                el.click()
            except Exception:
                driver.execute_script("arguments[0].click();", el)
            time.sleep(MED_SLEEP)
            step.snap(f"S_CLICKED_nf_{name}_fuzzy", html=True)
            return el
    except Exception:
        pass
    step.snap(f"S_ERR_click_nf_{name}", html=True)
    raise Exception(f"open_nf_menu: unable to click NF '{name}' (last={last_err})")

# ---------------- New: click 'amf' sub-entry inside AMF panel ----------------
def click_amf_subentry(timeout=12):
    """
    Find and click the 'amf' sub-entry that appears under the AMF panel.
    Strategy:
      - Try to locate a panel/region that belongs to AMF (heuristics)
      - Search inside that region for exact 'amf' entries (exact text first)
      - Try child anchors/spans, ActionChains, JS click fallback
      - If nothing found, dump candidate outerHTMLs to debug file for analysis
    """
    step.snap("S_BEFORE_click_amf_subentry", html=True)
    wait_for_no_overlay(wait=8)
    time.sleep(SHORT_SLEEP)

    # Heuristics to find AMF panel container(s)
    panel_xps = [
        "//*[contains(translate(@id,'ABCDEFGHIJKLMNOPQRSTUVWXYZ','abcdefghijklmnopqrstuvwxyz'),'amf')]",               # id contains amf
        "//*[contains(translate(@class,'ABCDEFGHIJKLMNOPQRSTUVWXYZ','abcdefghijklmnopqrstuvwxyz'),'amf')]",            # class contains amf
        "//*[contains(translate(normalize-space(.),'ABCDEFGHIJKLMNOPQRSTUVWXYZ','abcdefghijklmnopqrstuvwxyz'),'amf') and (contains(@class,'panel') or contains(@class,'content') or contains(@role,'region'))]",
        # any visible container that includes the word 'AMF' in its text (likely panel header)
        "//*[contains(translate(normalize-space(.),'ABCDEFGHIJKLMNOPQRSTUVWXYZ','abcdefghijklmnopqrstuvwxyz'),'amf') and (self::div or self::section or self::aside)]",
    ]

    panels = []
    for xp in panel_xps:
        try:
            found = driver.find_elements(By.XPATH, xp)
            for f in found:
                if f not in panels:
                    panels.append(f)
        except Exception:
            continue

    # Fallback: if no panels found, consider whole document as context
    contexts = panels if panels else [driver]

    # Search inside contexts for exact 'amf' sub-entry first
    candidates = []
    for ctx in contexts:
        try:
            # exact match (case-insensitive)
            exacts = ctx.find_elements(By.XPATH, ".//*[translate(normalize-space(.),'ABCDEFGHIJKLMNOPQRSTUVWXYZ','abcdefghijklmnopqrstuvwxyz')='amf']")
            for e in exacts:
                if e not in candidates:
                    candidates.append(e)
            # contains ' amf ' or starts/ends (word boundaries)
            contains = ctx.find_elements(By.XPATH, ".//*[contains(translate(normalize-space(.),'ABCDEFGHIJKLMNOPQRSTUVWXYZ','abcdefghijklmnopqrstuvwxyz'),' amf ') or starts-with(translate(normalize-space(.),'ABCDEFGHIJKLMNOPQRSTUVWXYZ','abcdefghijklmnopqrstuvwxyz'),'amf ') or substring(translate(normalize-space(.),'ABCDEFGHIJKLMNOPQRSTUVWXYZ','abcdefghijklmnopqrstuvwxyz'), string-length(translate(normalize-space(.),'ABCDEFGHIJKLMNOPQRSTUVWXYZ','abcdefghijklmnopqrstuvwxyz')) - string-length('amf') +1)='amf']")
            for e in contains:
                if e not in candidates:
                    candidates.append(e)
            # also look for anchors / li elements inside context
            anchors = ctx.find_elements(By.XPATH, ".//a[contains(translate(normalize-space(.),'ABCDEFGHIJKLMNOPQRSTUVWXYZ','abcdefghijklmnopqrstuvwxyz'),'amf')]")
            for e in anchors:
                if e not in candidates:
                    candidates.append(e)
            lis = ctx.find_elements(By.XPATH, ".//li[contains(translate(normalize-space(.),'ABCDEFGHIJKLMNOPQRSTUVWXYZ','abcdefghijklmnopqrstuvwxyz'),'amf')]")
            for e in lis:
                if e not in candidates:
                    candidates.append(e)
        except Exception:
            continue

    # If still empty, do a global fuzzy search
    if not candidates:
        try:
            fuzzy = driver.find_elements(By.XPATH, "//*[contains(translate(normalize-space(.),'ABCDEFGHIJKLMNOPQRSTUVWXYZ','abcdefghijklmnopqrstuvwxyz'),'amf')]")
            for e in fuzzy:
                if e not in candidates:
                    candidates.append(e)
        except Exception:
            pass

    # Dump candidate info for debugging if none or many
    try:
        dump_lines = []
        dump_lines.append(f"amf_subentry candidates dump time={time.strftime('%Y-%m-%d %H:%M:%S')}\n")
        for i, el in enumerate(candidates[:200]):
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
        dump_file = os.path.join(DEBUG_DIR, f"amf_subentry_candidates_{int(time.time())}.txt")
        with open(dump_file, "w", encoding="utf-8") as fh:
            fh.writelines(dump_lines)
        print("[DEBUG] wrote amf_subentry candidate dump:", dump_file)
        step.snap("S_AFTER_amf_subentry_candidates_dump", html=True)
    except Exception as e:
        print("Failed to dump amf_subentry candidates:", e)

    # Try to click candidates (prioritize visible exact matches)
    for el in candidates:
        try:
            txt = ""
            try:
                txt = (el.text or "").strip()
            except Exception:
                txt = ""
            # prefer exact 'amf'
            if txt and txt.lower() == "amf":
                try:
                    driver.execute_script("arguments[0].scrollIntoView({block:'center'});", el)
                except Exception:
                    pass
                time.sleep(0.12)
                if robust_click_target(el):
                    step.snap("S_CLICK_amf_subentry_exact", html=True)
                    print("Clicked amf subentry (exact text).")
                    return True
        except Exception:
            continue

    # Try clicking anchors/spans inside candidates
    for el in candidates:
        try:
            try:
                a = el.find_element(By.XPATH, ".//a[normalize-space(.)!='']")
                if a.is_displayed():
                    try:
                        a.click()
                    except Exception:
                        driver.execute_script("arguments[0].click();", a)
                    step.snap("S_CLICK_amf_subentry_child_a", html=True)
                    print("Clicked child <a> inside candidate")
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
                    step.snap("S_CLICK_amf_subentry_child_span", html=True)
                    print("Clicked child <span> inside candidate")
                    return True
            except Exception:
                pass

            # action chains on candidate
            try:
                ActionChains(driver).move_to_element(el).pause(0.08).click(el).perform()
                step.snap("S_CLICK_amf_subentry_actionchains", html=True)
                print("Clicked candidate via ActionChains")
                return True
            except Exception:
                pass

            # JS click fallback
            try:
                driver.execute_script("arguments[0].click();", el)
                step.snap("S_CLICK_amf_subentry_js", html=True)
                print("Clicked candidate via JS click fallback")
                return True
            except Exception:
                pass
        except Exception:
            continue

    # Final fuzzy pass (global click attempt)
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
                step.snap("S_CLICK_amf_subentry_fuzzy", html=True)
                print("Clicked fuzzy element containing 'amf'")
                return True
            except Exception:
                continue
    except Exception:
        pass

    step.snap("S_ERR_click_amf_subentry_final", html=True)
    raise Exception("click_amf_subentry: unable to locate or click the 'amf' sub-entry. Check amf_subentry_candidates_*.txt and screenshots.")

# ---------------- verify AMF panel presence ----------------
def wait_for_amf_panel(timeout=12):
    end = time.time() + timeout
    while time.time() < end:
        try:
            # file input visible?
            file_inputs = driver.find_elements(By.XPATH, "//input[@type='file']")
            for fi in file_inputs:
                try:
                    if fi.is_displayed():
                        return True
                except Exception:
                    continue
            # buttons containing textual hints
            hints = ["choose", "browse", "choose file", "select file", "import", "persist", "upload"]
            for h in hints:
                nodes = driver.find_elements(By.XPATH, f"//*[contains(translate(normalize-space(.),'ABCDEFGHIJKLMNOPQRSTUVWXYZ','abcdefghijklmnopqrstuvwxyz'),'{h}')]")
                for n in nodes:
                    try:
                        if n.is_displayed():
                            return True
                    except Exception:
                        continue
            # check for panel text
            possible_panels = driver.find_elements(By.XPATH, "//*[contains(@class,'panel') or contains(@class,'content') or contains(@id,'amf') or contains(@id,'AMF')]")
            for p in possible_panels:
                try:
                    if p.is_displayed() and p.text and len(p.text) > 5:
                        if "amf" in p.text.lower() or "import" in p.text.lower() or "choose" in p.text.lower():
                            return True
                except Exception:
                    continue
        except Exception:
            pass
        time.sleep(0.4)
    return False

# ---------------- upload helpers ----------------
def upload_config_file(file_path):
    step.snap("S_BEFORE_upload", html=True)
    selectors = ["//input[@type='file']","//input[contains(@class,'file') and @type='file']","//input[contains(@id,'file') and @type='file']"]
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
        raise Exception("upload_config_file: no file input")

def click_import():
    step.snap("S_BEFORE_import", html=True)
    texts = ["persist configurations", "persist", "import", "upload","persist configuration", "save configuration"]
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

def click_apply():
    step.snap("S_BEFORE_apply", html=True)
    try:
        driver.execute_script("window.scrollBy(0, 300);")
    except Exception:
        pass
    time.sleep(SHORT_SLEEP)
    words = ["apply","apply changes","confirm","ok","yes"]
    for w in words:
        try:
            nodes = driver.find_elements(By.XPATH, f"//*[contains(translate(normalize-space(.),'ABCDEFGHIJKLMNOPQRSTUVWXYZ','abcdefghijklmnopqrstuvwxyz'), '{w}')]")
            btn = _first_visible(nodes)
            if btn:
                try: btn.click()
                except Exception: driver.execute_script("arguments[0].click();", btn)
                time.sleep(MED_SLEEP)
                step.snap("S_AFTER_apply", html=True)
                handle_native_alerts(timeout=6, accept=True)
                return True
        except Exception:
            continue
    step.snap("S_ERR_apply_not_found", html=True)
    raise Exception("click_apply: not found")

# ---------------- Main flow ----------------
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

        # Click Configure (original-style)
        try:
            open_configure_menu()
        except Exception as e:
            print("open_configure_menu failed:", e)
            step.snap("S_ERR_configure_click", html=True)
            raise

        time.sleep(SHORT_SLEEP)

        # Click AMF category (original-style)
        try:
            open_nf_menu("AMF")
        except Exception as e:
            print("open_nf_menu('AMF') failed:", e)
            step.snap("S_ERR_amf_menu_click", html=True)
            raise

        time.sleep(SHORT_SLEEP)

        # Now click the sub-entry "amf" under AMF (new explicit step)
        try:
            click_amf_subentry()
        except Exception as e:
            print("click_amf_subentry failed:", e)
            step.snap("S_ERR_amf_subentry_click", html=True)
            raise

        # Verify AMF panel is ready (file input or import/persist hints)
        if not wait_for_amf_panel(timeout=12):
            # dump candidates and fail with useful message
            try:
                candidates = driver.find_elements(By.XPATH, "//*[contains(translate(normalize-space(.),'ABCDEFGHIJKLMNOPQRSTUVWXYZ','abcdefghijklmnopqrstuvwxyz'),'amf')]")
                dump = []
                for i, c in enumerate(candidates[:200]):
                    try:
                        outer = driver.execute_script("return arguments[0].outerHTML;", c)
                    except Exception:
                        outer = "<outerHTML unavailable>"
                    vis = False
                    try: vis = c.is_displayed()
                    except Exception: vis = False
                    dump.append(f"--- cand {i} visible={vis} ---\n{outer}\n\n")
                dump_file = os.path.join(DEBUG_DIR, f"amf_subentry_candidates_{int(time.time())}.txt")
                with open(dump_file, "w", encoding="utf-8") as fh:
                    fh.writelines(dump)
                print("[DEBUG] amf_subentry candidates dump:", dump_file)
                step.snap("S_AFTER_amf_subentry_candidates_dump", html=True)
            except Exception as e:
                print("Failed to dump amf candidates:", e)
            raise Exception("AMF panel did not appear after clicking amf sub-entry; check debug artifacts.")

        step.snap("S_AFTER_amf_panel_ready", html=True)
        time.sleep(SHORT_SLEEP)

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

            # click ok if present
            try:
                okbtn = _first_visible(driver.find_elements(By.XPATH, "//*[contains(translate(normalize-space(.),'ABCDEFGHIJKLMNOPQRSTUVWXYZ','abcdefghijklmnopqrstuvwxyz'),'ok') and (self::button or self::a)]"))
                if okbtn:
                    try: okbtn.click()
                    except Exception: driver.execute_script("arguments[0].click();", okbtn)
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
