#!/usr/bin/env python3
# gui_upload.py  (v3, 2025-09-16)
# AMF-only upload automation:
#   Configure -> AMF -> "amf" entry -> upload JSON -> Persist -> (native confirm) -> [Apply if needed]
#
# Highlights in v3:
# - Robust login (cert interstitial, iframe/SSO-aware, doc.ready)
# - Explicit native confirm handling after "Persist Configurations"
# - Skip Apply when persist is final (based on alert text heuristic)
# - Scroll-aware + modal/iframe-aware Apply retained (if Apply exists)
# - FAST_MODE to trim timeouts; larger headless viewport
# - Rich debug artifacts (.png + .html)
#
# Usage:
#   CONFIG_DIR=/path/to/configs HEADLESS=1 FAST_MODE=0 ./venv/bin/python scripts/gui_upload.py

import os
import time
import traceback

from selenium import webdriver
from selenium.webdriver.firefox.options import Options
from selenium.webdriver.common.by import By
from selenium.webdriver.common.keys import Keys
from selenium.webdriver.support.ui import WebDriverWait
from selenium.webdriver.support import expected_conditions as EC

from selenium.common.exceptions import (
    TimeoutException,
    UnexpectedAlertPresentException,
    NoAlertPresentException,
)

# ---------------------- Version banner ----------------------
print("gui_upload.py version: v3 (2025-09-16) - robust login, persist-final fast path, scroll-apply")

# ---------------------- Config ----------------------
url = "https://172.27.28.193.nip.io/ems/login"
username = "root"
password = "root123"

config_dir = os.environ.get("CONFIG_DIR", "config_files")
debug_dir = "debug_screenshots"
os.makedirs(debug_dir, exist_ok=True)

# Speed knobs
FAST_MODE = os.environ.get("FAST_MODE", "0") == "1"
OVERLAY_TIMEOUT = 6 if FAST_MODE else 12
SHORT_SLEEP = 0.2 if FAST_MODE else 0.5
SCROLL_ATTEMPTS = 1 if FAST_MODE else 2

# Global flag indicating persist action is final (skip Apply)
PERSIST_IS_FINAL = False

# ---------------------- WebDriver setup ----------------------
options = Options()
headless = os.environ.get("HEADLESS", "1")
if headless != "0":
    options.add_argument("--headless")
options.add_argument("--no-sandbox")
options.add_argument("--disable-dev-shm-usage")
options.accept_insecure_certs = True

# Prefer moving on after DOMContentLoaded (can speed up page loads)
try:
    options.set_capability("pageLoadStrategy", "eager")
except Exception:
    pass

# Safety net: accept any unhandled prompts if they slip through
try:
    options.set_capability("unhandledPromptBehavior", "accept")
except Exception:
    pass

driver = webdriver.Firefox(options=options)

# Make the headless viewport tall so bottom bars/footers are visible
try:
    driver.set_window_size(1500, 2200)
except Exception:
    pass

# ---------------------- Utility/Debug helpers ----------------------
def wait_document_ready(timeout=25):
    end = time.time() + timeout
    while time.time() < end:
        try:
            ready = driver.execute_script("return document.readyState")
            if ready == "complete":
                return True
        except Exception:
            pass
        time.sleep(0.2)
    return False

def save_debug(name):
    """Take a screenshot; if a native prompt blocks it, accept and retry once."""
    try:
        handle_native_alerts(timeout=1, accept=True)
    except Exception:
        pass

    path = os.path.join(debug_dir, f"{int(time.time())}_{name}.png")
    try:
        driver.save_screenshot(path)
        print(f"Saved screenshot: {path}")
    except Exception as e:
        print(f"Failed to save screenshot {path}: {e}")
        if handle_native_alerts(timeout=2, accept=True):
            time.sleep(0.2)
            try:
                driver.save_screenshot(path)
                print(f"Saved screenshot (retry): {path}")
            except Exception as e2:
                print(f"Retry failed to save screenshot {path}: {e2}")

def _save_page_source(name):
    path = os.path.join(debug_dir, f"{int(time.time())}_{name}.html")
    try:
        with open(path, "w", encoding="utf-8") as fh:
            fh.write(driver.page_source)
        print(f"Saved page source: {path}")
    except Exception as e:
        print(f"Failed to save page source {path}: {e}")

def handle_native_alerts(timeout=8, accept=True):
    """
    Wait for window.alert/confirm/prompt and accept/dismiss it.
    Returns alert text ('' if none).
    """
    try:
        WebDriverWait(driver, timeout).until(EC.alert_is_present())
        alert = driver.switch_to.alert
        text = ""
        try:
            text = alert.text or ""
            print("Native alert text:", text)
        except Exception:
            pass
        if accept:
            alert.accept()
            print("Native alert accepted")
        else:
            alert.dismiss()
            print("Native alert dismissed")
        time.sleep(SHORT_SLEEP)
        return text
    except TimeoutException:
        return ""
    except Exception as e:
        print("Error while handling native alert:", e)
        return ""

# ---------------------- Login helpers ----------------------
def handle_firefox_cert_interstitial(max_tries=2):
    """
    Accept Firefox 'Warning: Potential Security Risk Ahead' interstitial if shown.
    """
    for _ in range(max_tries):
        try:
            cur = driver.current_url or ""
        except Exception:
            cur = ""
        if "about:certerror" in cur or "certerror" in cur.lower():
            print("Detected Firefox certificate interstitial; attempting to accept risk...")
            try:
                # Expand advanced panel
                try:
                    driver.find_element(By.ID, "advancedButton").click()
                    time.sleep(0.3)
                except Exception:
                    pass
                # Accept the risk and continue
                for btn_id in ("acceptTheRiskButton", "exceptionDialogButton"):
                    try:
                        btn = driver.find_element(By.ID, btn_id)
                        driver.execute_script("arguments[0].click();", btn)
                        time.sleep(1.2)
                        break
                    except Exception:
                        continue
            except Exception as e:
                print("Cert interstitial handling error:", e)
            time.sleep(0.8)
        else:
            break

def _first_visible(els):
    for e in els:
        try:
            if e.is_displayed():
                return e
        except Exception:
            continue
    return None

def _find_in_iframes(find_fn):
    """Run a finder inside each iframe and return the first visible element found + frame."""
    frames = driver.find_elements(By.TAG_NAME, "iframe")
    for idx, fr in enumerate(frames):
        try:
            driver.switch_to.frame(fr)
            el = find_fn()
            if el:
                print(f"Found element in iframe[{idx}]")
                driver.switch_to.default_content()
                return (el, fr)
        except Exception:
            pass
        finally:
            try:
                driver.switch_to.default_content()
            except Exception:
                pass
    return (None, None)

def locate_login_fields(timeout=30):
    """
    Return (username_input, password_input, login_button or None).
    Scans main page and iframes with broad patterns.
    """
    end = time.time() + timeout

    user_xps = [
        "//input[@type='text' or @type='email']",
        "//input[contains(translate(@name,'ABCDEFGHIJKLMNOPQRSTUVWXYZ','abcdefghijklmnopqrstuvwxyz'),'user') or contains(translate(@id,'ABCDEFGHIJKLMNOPQRSTUVWXYZ','abcdefghijklmnopqrstuvwxyz'),'user')]",
        "//input[contains(translate(@name,'ABCDEFGHIJKLMNOPQRSTUVWXYZ','abcdefghijklmnopqrstuvwxyz'),'login') or contains(translate(@id,'ABCDEFGHIJKLMNOPQRSTUVWXYZ','abcdefghijklmnopqrstuvwxyz'),'login')]",
        "//input[contains(translate(@placeholder,'ABCDEFGHIJKLMNOPQRSTUVWXYZ','abcdefghijklmnopqrstuvwxyz'),'user') or contains(translate(@placeholder,'ABCDEFGHIJKLMNOPQRSTUVWXYZ','abcdefghijklmnopqrstuvwxyz'),'email')]",
    ]
    pass_xps = [
        "//input[@type='password']",
        "//input[contains(translate(@name,'ABCDEFGHIJKLMNOPQRSTUVWXYZ','abcdefghijklmnopqrstuvwxyz'),'pass') or contains(translate(@id,'ABCDEFGHIJKLMNOPQRSTUVWXYZ','abcdefghijklmnopqrstuvwxyz'),'pass')]",
    ]
    login_btn_xps = [
        "//button[contains(translate(normalize-space(.),'ABCDEFGHIJKLMNOPQRSTUVWXYZ','abcdefghijklmnopqrstuvwxyz'),'login')]",
        "//button[contains(translate(normalize-space(.),'ABCDEFGHIJKLMNOPQRSTUVWXYZ','abcdefghijklmnopqrstuvwxyz'),'sign in')]",
        "//input[@type='submit']",
        "//a[contains(translate(normalize-space(.),'ABCDEFGHIJKLMNOPQRSTUVWXYZ','abcdefghijklmnopqrstuvwxyz'),'login') or contains(translate(normalize-space(.),'ABCDEFGHIJKLMNOPQRSTUVWXYZ','abcdefghijklmnopqrstuvwxyz'),'sign in')]",
    ]

    def find_fields_in_context():
        # username
        u = None
        for xp in user_xps:
            els = driver.find_elements(By.XPATH, xp)
            u = _first_visible(els)
            if u:
                break
        # password
        p = _first_visible(driver.find_elements(By.XPATH, pass_xps[0])) \
            or _first_visible(driver.find_elements(By.XPATH, pass_xps[1]))
        # login button (optional)
        b = None
        for xp in login_btn_xps:
            b = _first_visible(driver.find_elements(By.XPATH, xp))
            if b:
                break
        return (u, p, b)

    while time.time() < end:
        try:
            u, p, b = find_fields_in_context()
            if u and p:
                return (u, p, b)
            # try iframes
            def inner():
                u2, p2, b2 = find_fields_in_context()
                return _first_visible([u2, p2, b2])
            el, fr = _find_in_iframes(inner)
            if el:
                # Re-enter iframe to fetch concrete fields
                driver.switch_to.frame(fr)
                u, p, b = find_fields_in_context()
                driver.switch_to.default_content()
                if u and p:
                    return (u, p, b)
        except Exception:
            pass
        time.sleep(0.3)

    return (None, None, None)

def robust_login_flow():
    driver.get(url)
    wait_document_ready(timeout=25)
    handle_firefox_cert_interstitial(max_tries=2)

    # Log current URL & title for debugging
    try:
        print("Login page URL:", driver.current_url)
        print("Login page title:", driver.title)
    except Exception:
        pass

    u, p, btn = locate_login_fields(timeout=30)
    if not u or not p:
        save_debug("login_failed")
        _save_page_source("login_failed")
        raise TimeoutException("Could not find username/password fields on the login page")

    # Fill credentials
    try:
        u.clear()
    except Exception:
        pass
    u.send_keys(username)

    try:
        p.clear()
    except Exception:
        pass
    p.send_keys(password)

    # Click login OR press Enter in password field
    if btn:
        try:
            btn.click()
        except Exception:
            driver.execute_script("arguments[0].click();", btn)
    else:
        p.send_keys("\n")

    time.sleep(2.0)
    save_debug("after_login")

# ---------------------- Generic element finder ----------------------
def find_element_by_text_any(tag_text, timeout=6):
    """
    Find an element containing tag_text (case-insensitive) using multiple strategies.
    Raises Exception if not found and saves page source for debugging.
    """
    lower_text = tag_text.lower()
    xpaths = [
        f"//*[contains(translate(normalize-space(.), 'ABCDEFGHIJKLMNOPQRSTUVWXYZ', 'abcdefghijklmnopqrstuvwxyz'), '{lower_text}')]",
        f"//*[contains(translate(text(), 'ABCDEFGHIJKLMNOPQRSTUVWXYZ', 'abcdefghijklmnopqrstuvwxyz'), '{lower_text}')]",
    ]

    # 1) quick XPath attempts
    for xp in xpaths:
        try:
            elem = WebDriverWait(driver, timeout).until(
                EC.presence_of_element_located((By.XPATH, xp))
            )
            return elem
        except Exception:
            pass

    # 2) scan visible elements by tag names
    candidate_tags = ["a", "button", "div", "span", "li", "label", "td", "th", "*"]
    try:
        for tag in candidate_tags:
            try:
                els = driver.find_elements(By.TAG_NAME, tag)
            except Exception:
                continue
            for e in els:
                try:
                    text = (e.text or "").strip()
                    if text and lower_text in text.lower():
                        print(f"Found by element.text in tag <{tag}>: '{text[:80]}'")
                        return e
                except Exception:
                    continue
    except Exception:
        pass

    # 3) scan attributes
    attrs = ["title", "aria-label", "data-testid", "data-test", "alt", "role", "placeholder", "id", "class", "name"]
    try:
        els = driver.find_elements(By.XPATH, "//*")
        for e in els:
            try:
                for a in attrs:
                    try:
                        val = e.get_attribute(a)
                    except Exception:
                        val = None
                    if val and lower_text in val.lower():
                        print(f"Found by attribute {a}='{val[:80]}'")
                        return e
            except Exception:
                continue
    except Exception:
        pass

    # 4) try inside iframes
    try:
        iframes = driver.find_elements(By.TAG_NAME, "iframe")
        if iframes:
            print(f"Found {len(iframes)} iframe(s); scanning them for '{tag_text}'")
            for idx, fr in enumerate(iframes):
                try:
                    driver.switch_to.frame(fr)
                    for xp in xpaths:
                        try:
                            elem = WebDriverWait(driver, 1).until(
                                EC.presence_of_element_located((By.XPATH, xp))
                            )
                            driver.switch_to.default_content()
                            return elem
                        except Exception:
                            pass
                    inner_els = driver.find_elements(By.XPATH, "//*")
                    for e in inner_els:
                        try:
                            for a in attrs:
                                val = e.get_attribute(a)
                                if val and lower_text in val.lower():
                                    driver.switch_to.default_content()
                                    print(f"Found in iframe[{idx}] by attribute {a}='{val[:80]}'")
                                    return e
                        except Exception:
                            continue
                except Exception:
                    pass
                finally:
                    try:
                        driver.switch_to.default_content()
                    except Exception:
                        pass
    except Exception:
        pass

    # not found: save and raise
    _save_page_source(f"no_elem_{tag_text}")
    raise Exception(f"Element containing text '{tag_text}' not found using candidate strategies.")

# ---------------------- Click helpers ----------------------
def click_element_via_js(elem):
    driver.execute_script("arguments[0].scrollIntoView({block:'center', inline:'center'});", elem)
    driver.execute_script("arguments[0].click();", elem)

def open_configure_menu():
    """Click 'Configure' in the left sidebar so NF icons/list appear."""
    print("Attempting to open 'Configure' menu...")
    candidate_xps = [
        "//nav//a//*[contains(translate(normalize-space(.), 'ABCDEFGHIJKLMNOPQRSTUVWXYZ','abcdefghijklmnopqrstuvwxyz'), 'configure')]",
        "//a[contains(translate(normalize-space(.), 'ABCDEFGHIJKLMNOPQRSTUVWXYZ','abcdefghijklmnopqrstuvwxyz'), 'configure')]",
        "//*[contains(translate(normalize-space(.), 'ABCDEFGHIJKLMNOPQRSTUVWXYZ','abcdefghijklmnopqrstuvwxyz'), 'configure')]",
        "//*[@aria-label and contains(translate(@aria-label,'ABCDEFGHIJKLMNOPQRSTUVWXYZ','abcdefghijklmnopqrstuvwxyz'), 'configure')]",
        "//*[@title and contains(translate(@title,'ABCDEFGHIJKLMNOPQRSTUVWXYZ','abcdefghijklmnopqrstuvwxyz'), 'configure')]",
    ]
    for xp in candidate_xps:
        try:
            el = WebDriverWait(driver, 5).until(EC.element_to_be_clickable((By.XPATH, xp)))
            try:
                el.click()
            except Exception:
                driver.execute_script("arguments[0].click();", el)
            print("Clicked 'Configure' via XPath:", xp)
            time.sleep(0.3 if FAST_MODE else 1.0)
            return
        except Exception:
            continue
    # fallback: find by visible text
    try:
        el = find_element_by_text_any("Configure", timeout=3)
        try:
            el.click()
        except Exception:
            driver.execute_script("arguments[0].click();", el)
        print("Clicked 'Configure' (fallback)")
        time.sleep(0.3 if FAST_MODE else 1.0)
        return
    except Exception as e:
        print(f"Warning: Could not open 'Configure' menu: {e}")
        _save_page_source("configure_not_opened")
        raise

def click_nf_tab(driver, nf_name):
    """Open Configure and click the NF tab (AMF/SMF/UPF)."""
    try:
        try:
            open_configure_menu()
        except Exception:
            print("Configure open failed; continuing (maybe already open).")

        print(f"Looking for NF tab '{nf_name}'")
        elem = find_element_by_text_any(nf_name, timeout=6)
        try:
            driver.execute_script("arguments[0].scrollIntoView({block:'center'});", elem)
            time.sleep(SHORT_SLEEP)
        except Exception:
            pass
        try:
            elem.click()
            time.sleep(SHORT_SLEEP)
        except Exception:
            driver.execute_script("arguments[0].click();", elem)
            time.sleep(SHORT_SLEEP)
        print(f"Clicked NF tab '{nf_name}'")
    except Exception as e:
        _save_page_source(f"click_lookup_failed_{nf_name}")
        print(f"Error clicking NF tab '{nf_name}': {e}")
        raise

def click_nf_entry(driver, entry_text):
    """Click the NF list item inside the NF panel (e.g., 'amf')."""
    try:
        print(f"Looking for NF entry '{entry_text}' (inside NF panel)...")
        elem = find_element_by_text_any(entry_text, timeout=8)
        try:
            driver.execute_script("arguments[0].scrollIntoView({block:'center'});", elem)
            time.sleep(SHORT_SLEEP)
        except Exception:
            pass
        try:
            elem.click()
            time.sleep(SHORT_SLEEP)
        except Exception:
            driver.execute_script("arguments[0].click();", elem)
            time.sleep(SHORT_SLEEP)
        print(f"Clicked NF entry '{entry_text}'")
    except Exception as e:
        _save_page_source(f"nf_entry_not_found_{entry_text}")
        print(f"Error clicking NF entry '{entry_text}': {e}")
        raise

# ---------------------- Upload helpers ----------------------
def upload_config_file(driver, file_path):
    """
    Robust upload:
    - waits for input[type=file] with extended timeout
    - tries multiple selectors
    - clicks 'Choose/Browse/Select' triggers and searches in iframes
    - unhides input if necessary
    - injects a temporary input as last resort
    """
    print(f"Attempting to upload file: {file_path}")
    selectors = [
        "//input[@type='file']",
        "//input[contains(@class,'file') and @type='file']",
        "//input[contains(@id,'file') and @type='file']",
        "//input[contains(@name,'file') and @type='file']",
        "//input[contains(@data-test,'file') and @type='file']",
    ]
    time.sleep(SHORT_SLEEP)

    # 1) try with a larger wait
    for sel in selectors:
        try:
            file_input = WebDriverWait(driver, 12).until(
                EC.presence_of_element_located((By.XPATH, sel))
            )
            print(f"Found file input by xpath: {sel}")
            try:
                driver.execute_script("arguments[0].style.display='block'; arguments[0].style.visibility='visible'; arguments[0].style.height='1px';", file_input)
            except Exception:
                pass
            file_input.send_keys(file_path)
            print("Sent file path to input (xpath path)")
            time.sleep(SHORT_SLEEP)
            return
        except Exception:
            continue

    # 2) find any input[type=file] without wait
    try:
        els = driver.find_elements(By.XPATH, "//input[@type='file']")
        if els:
            print(f"Found {len(els)} input[type=file] via find_elements")
            for e in els:
                try:
                    driver.execute_script("arguments[0].style.display='block'; arguments[0].style.visibility='visible';", e)
                    e.send_keys(file_path)
                    print("Sent file path to one of the inputs")
                    time.sleep(SHORT_SLEEP)
                    return
                except Exception:
                    continue
    except Exception:
        pass

    # 3) Click Choose/Browse/Select UI controls to reveal input
    choose_xps = [
        "//label[contains(translate(normalize-space(.),'ABCDEFGHIJKLMNOPQRSTUVWXYZ','abcdefghijklmnopqrstuvwxyz'),'choose')]",
        "//label[contains(translate(normalize-space(.),'ABCDEFGHIJKLMNOPQRSTUVWXYZ','abcdefghijklmnopqrstuvwxyz'),'browse')]",
        "//button[contains(translate(normalize-space(.),'ABCDEFGHIJKLMNOPQRSTUVWXYZ','abcdefghijklmnopqrstuvwxyz'),'choose')]",
        "//button[contains(translate(normalize-space(.),'ABCDEFGHIJKLMNOPQRSTUVWXYZ','abcdefghijklmnopqrstuvwxyz'),'browse')]",
        "//*[contains(translate(normalize-space(.),'ABCDEFGHIJKLMNOPQRSTUVWXYZ','abcdefghijklmnopqrstuvwxyz'),'select file')]",
        "//*[contains(translate(normalize-space(.),'ABCDEFGHIJKLMNOPQRSTUVWXYZ','abcdefghijklmnopqrstuvwxyz'),'select')]",
    ]
    for xp in choose_xps:
        try:
            btn = WebDriverWait(driver, 2).until(EC.element_to_be_clickable((By.XPATH, xp)))
            print("Clicking 'Choose/Browse' element:", xp)
            try:
                btn.click()
            except Exception:
                driver.execute_script("arguments[0].click();", btn)
            time.sleep(0.3)
            try:
                file_input = WebDriverWait(driver, 3).until(
                    EC.presence_of_element_located((By.XPATH, "//input[@type='file']"))
                )
                driver.execute_script("arguments[0].style.display='block'; arguments[0].style.visibility='visible';", file_input)
                file_input.send_keys(file_path)
                print("Sent file path after clicking choose/browse")
                time.sleep(SHORT_SLEEP)
                return
            except Exception:
                pass
        except Exception:
            continue

    # 4) try inside iframes
    try:
        iframes = driver.find_elements(By.TAG_NAME, "iframe")
        print(f"Scanning {len(iframes)} iframe(s) for input[type=file]")
        for idx, fr in enumerate(iframes):
            try:
                driver.switch_to.frame(fr)
                found = False
                for sel in selectors:
                    try:
                        file_input = driver.find_element(By.XPATH, sel)
                        print(f"Found input in iframe[{idx}] by {sel}")
                        try:
                            driver.execute_script("arguments[0].style.display='block'; arguments[0].style.visibility='visible';", file_input)
                        except Exception:
                            pass
                        file_input.send_keys(file_path)
                        found = True
                        time.sleep(SHORT_SLEEP)
                        break
                    except Exception:
                        continue
                driver.switch_to.default_content()
                if found:
                    return
            except Exception:
                try:
                    driver.switch_to.default_content()
                except Exception:
                    pass
                continue
    except Exception:
        pass

    # 5) Last resort: inject temporary input
    try:
        unique_id = f"tmp_upload_{int(time.time())}"
        js = (
            "var inp = document.createElement('input');"
            "inp.type='file'; inp.id=arguments[0];"
            "inp.style.display='block'; inp.style.visibility='visible';"
            "document.body.appendChild(inp);"
            "return inp;"
        )
        driver.execute_script(js, unique_id)
        tmp = driver.find_element(By.ID, unique_id)
        tmp.send_keys(file_path)
        print("Injected temporary input and sent file path.")
        time.sleep(SHORT_SLEEP)
        return
    except Exception as e:
        print("Failed to inject/use temporary input:", e)

    _save_page_source("file_input_error")
    save_debug("file_input_error")
    raise Exception("Could not locate file input element to upload the config file.")

# ---------------------- Import / Apply helpers ----------------------
def click_import(driver):
    """
    Broadened import/persist detection: looks for buttons like
    'Persist Configurations', 'Persist', 'Import', 'Save configuration', 'Save', 'Upload'.
    Explicitly accepts the native confirm after clicking Persist.
    Sets global PERSIST_IS_FINAL when alert text indicates final commit.
    """
    global PERSIST_IS_FINAL
    try:
        print("Looking for 'Persist Configurations' / Import button...")
        texts = ["persist configurations", "persist", "import", "upload", "save configuration", "save"]
        for t in texts:
            try:
                btn = WebDriverWait(driver, 12).until(
                    EC.element_to_be_clickable(
                        (By.XPATH, "//button[contains(translate(normalize-space(.), 'ABCDEFGHIJKLMNOPQRSTUVWXYZ','abcdefghijklmnopqrstuvwxyz'), '%s')]" % t)
                    )
                )
                try:
                    btn.click()
                except Exception:
                    driver.execute_script("arguments[0].click();", btn)
                print(f"Clicked import-like button: '{t}'")

                # Accept native confirm (if any) and inspect its text
                alert_text = handle_native_alerts(timeout=8, accept=True)
                if alert_text:
                    print("Confirmed 'Persist Configurations' native dialog")
                    # Heuristic: if alert says we're copying running->startup for ALL NFs,
                    # treat this as final commit; skip Apply.
                    lt = alert_text.lower()
                    if "all nfs" in lt or ("running" in lt and "startup" in lt):
                        PERSIST_IS_FINAL = True
                        print("Persist appears final (no Apply needed).")

                return
            except Exception:
                continue
        raise Exception("No import/persist/upload button found")
    except Exception as e:
        print(f"Error clicking import/persist: {e}")
        driver.save_screenshot(f"debug_screenshots/{int(time.time())}_error_persist_config.png")
        raise

def scroll_page(step_ratio=0.85, attempts=6, direction="down"):
    """Progressively scroll the main window."""
    dy = "Math.floor(window.innerHeight*arguments[0])"
    for _ in range(attempts):
        if direction == "down":
            driver.execute_script(f"window.scrollBy(0, {dy});", step_ratio)
        else:
            driver.execute_script(f"window.scrollBy(0, -{dy});", step_ratio)
        time.sleep(0.2)

def scroll_all_scrollables_to_bottom():
    """
    Find likely scrollable containers (overflow panels, side panes, content areas)
    and scroll them to bottom.
    """
    xps = [
        "//*[contains(@class,'scroll') or contains(@class,'content') or contains(@class,'container') or contains(@class,'panel') or contains(@style,'overflow')]",
    ]
    for xp in xps:
        try:
            els = driver.find_elements(By.XPATH, xp)
            for el in els:
                try:
                    is_scrollable = driver.execute_script(
                        "return arguments[0].scrollHeight > arguments[0].clientHeight;", el
                    )
                    if is_scrollable and el.is_displayed():
                        driver.execute_script("arguments[0].scrollTop = arguments[0].scrollHeight;", el)
                        time.sleep(0.1)
                except Exception:
                    continue
        except Exception:
            continue

def _find_modal_roots():
    """
    Return a list of likely modal/dialog root elements.
    """
    modal_xps = [
        "//*[@role='dialog']",
        "//*[contains(@class,'modal') or contains(@class,'dialog')]",
        "//*[contains(@class,'cdk-overlay-pane')]",
        "//*[contains(@class,'MuiDialog-root')]",
        "//*[contains(@class,'ant-modal') or contains(@class,'ant-modal-root')]",
        "//*[contains(@class,'p-dialog') or contains(@class,'p-dialog-content')]",
    ]
    roots = []
    for xp in modal_xps:
        try:
            roots.extend(driver.find_elements(By.XPATH, xp))
        except Exception:
            continue
    return [r for r in roots if r.is_displayed()]

def _click_in(el):
    try:
        el.click()
    except Exception:
        driver.execute_script("arguments[0].click();", el)

def _find_clickable_in_context(root, xpath, timeout=6):
    """Wait up to timeout seconds for a descendant matching xpath to be visible."""
    end = time.time() + timeout
    while time.time() < end:
        try:
            el = root.find_element(By.XPATH, xpath)
            if el.is_displayed():
                return el
        except Exception:
            pass
        time.sleep(0.2)
    return None

def find_apply_like_button(context=None, timeout=6):
    """
    Search for Apply-like buttons in common action bars/footers first, then anywhere in the context.
    Returns the WebElement or None.
    """
    root = context if context is not None else driver
    btn_texts = ["apply", "apply changes", "confirm", "proceed", "ok", "yes", "submit", "update", "save", "continue"]

    # Prefer action bars/footers/button-bars
    footer_xps = [
        ".//*[contains(@class,'action') or contains(@class,'footer') or contains(@class,'button-bar') or contains(@class,'btn-toolbar')]" if context is not None
        else "//*[contains(@class,'action') or contains(@class,'footer') or contains(@class,'button-bar') or contains(@class,'btn-toolbar')]"
    ]
    try:
        footers = []
        for xp in footer_xps:
            try:
                footers.extend(root.find_elements(By.XPATH, xp))
            except Exception:
                continue
        footers = [f for f in footers if f.is_displayed()]
        for ftr in footers:
            for t in btn_texts:
                btn = _find_clickable_in_context(
                    ftr,
                    ".//*[self::button or self::a or self::span or self::div]"
                    "[contains(translate(normalize-space(.), 'ABCDEFGHIJKLMNOPQRSTUVWXYZ','abcdefghijklmnopqrstuvwxyz'), '%s')]" % t,
                    timeout=2
                )
                if btn:
                    return btn
    except Exception:
        pass

    # Fallback: search anywhere in the root
    for t in btn_texts:
        try:
            btn = WebDriverWait(driver if context is None else driver, timeout).until(
                EC.element_to_be_clickable((
                    By.XPATH,
                    ("//*[self::button or self::a or self::span or self::div]"
                     "[contains(translate(normalize-space(.), 'ABCDEFGHIJKLMNOPQRSTUVWXYZ','abcdefghijklmnopqrstuvwxyz'), '%s')]" % t)
                ))
            )
            return btn
        except Exception:
            continue
    return None

def try_press_enter_fallback():
    try:
        driver.switch_to.active_element.send_keys(Keys.END)
        time.sleep(0.2)
        driver.switch_to.active_element.send_keys("\n")
        print("Sent END + Enter as fallback")
        time.sleep(0.5)
        return True
    except Exception:
        return False

def wait_for_overlay_to_settle(timeout=OVERLAY_TIMEOUT):
    """
    Wait for common UI overlays/spinners/toasts to disappear so buttons are clickable.
    Non-fatal if nothing is found.
    """
    overlay_xps = [
        "//*[contains(@class,'overlay') and contains(@class,'backdrop')]",
        "//*[contains(@class,'modal-backdrop')]",
        "//*[contains(@class,'cdk-overlay-backdrop')]",
        "//*[contains(@class,'MuiBackdrop-root')]",
        "//*[contains(@class,'ant-modal-wrap') and contains(@style,'display: none')=false]",
        "//*[contains(@class,'p-dialog-mask') and contains(@style,'display: none')=false]",
        "//*[contains(@class,'spinner') or contains(@class,'progress') or contains(@class,'loading')]",
    ]
    try:
        end = time.time() + timeout
        while time.time() < end:
            visible = False
            for xp in overlay_xps:
                try:
                    els = driver.find_elements(By.XPATH, xp)
                    if any(e.is_displayed() for e in els):
                        visible = True
                        break
                except Exception:
                    continue
            if not visible:
                return
            time.sleep(0.3)
    except Exception:
        pass

def click_apply(driver):
    """
    Scroll-aware and modal/iframe-aware Apply:
    - handle leftover native prompt (if any)
    - scroll page + scrollable containers to bottom
    - search for Apply/Confirm in action bars/footers or anywhere
    - if not found, try modal/iframe contexts
    - final fallback: press Enter on active element
    """
    try:
        # If a native confirm is still open, accept it first
        handle_native_alerts(timeout=2, accept=True)

        # Capture state and let UI settle a bit
        save_debug("after_persist_clicked")
        wait_for_overlay_to_settle(timeout=OVERLAY_TIMEOUT)
        time.sleep(SHORT_SLEEP)

        # 1) Scroll the page and scrollable containers
        scroll_page(step_ratio=1.0, attempts=SCROLL_ATTEMPTS, direction="down")
        scroll_all_scrollables_to_bottom()
        time.sleep(0.2)

        # 2) Try to find & click Apply-like button in the page
        btn = find_apply_like_button(timeout=6 if FAST_MODE else 10)
        if btn:
            driver.execute_script("arguments[0].scrollIntoView({block:'center'});", btn)
            time.sleep(0.2)
            try:
                btn.click()
            except Exception:
                driver.execute_script("arguments[0].click();", btn)
            print("Clicked Apply/Confirm in page body after scrolling")
            time.sleep(SHORT_SLEEP)
            wait_for_overlay_to_settle(timeout=OVERLAY_TIMEOUT)
            return

        # 3) Look for Apply-like button inside modals/dialogs if present
        modals = _find_modal_roots()
        for m in modals:
            # If the modal requires acknowledgements, tick obvious checkboxes
            try:
                for lbl in ["i understand", "acknowledge", "i agree", "confirm", "overwrite", "force", "accept", "proceed"]:
                    try:
                        lab = m.find_element(
                            By.XPATH,
                            ".//label[contains(translate(normalize-space(.), 'ABCDEFGHIJKLMNOPQRSTUVWXYZ','abcdefghijklmnopqrstuvwxyz'), '%s')]" % lbl
                        )
                        # click nearest checkbox in modal
                        cbs = m.find_elements(By.XPATH, ".//input[@type='checkbox']")
                        for cb in cbs:
                            try:
                                if not cb.is_selected() and cb.is_displayed():
                                    driver.execute_script("arguments[0].scrollIntoView({block:'center'});", cb)
                                    time.sleep(0.1)
                                    try:
                                        cb.click()
                                    except Exception:
                                        driver.execute_script("arguments[0].click();", cb)
                                    time.sleep(0.2)
                                    break
                            except Exception:
                                continue
                    except Exception:
                        continue
            except Exception:
                pass

            # Now try buttons inside the modal
            btn = find_apply_like_button(context=m, timeout=5)
            if btn:
                driver.execute_script("arguments[0].scrollIntoView({block:'center'});", btn)
                time.sleep(0.2)
                try:
                    btn.click()
                except Exception:
                    driver.execute_script("arguments[0].click();", btn)
                print("Clicked Apply/Confirm inside modal")
                time.sleep(SHORT_SLEEP)
                wait_for_overlay_to_settle(timeout=OVERLAY_TIMEOUT)
                return

        # 4) If dialog is inside an iframe, search there
        try:
            iframes = driver.find_elements(By.TAG_NAME, "iframe")
            for idx, fr in enumerate(iframes):
                try:
                    driver.switch_to.frame(fr)
                    btn = find_apply_like_button(timeout=4)
                    if btn:
                        driver.execute_script("arguments[0].scrollIntoView({block:'center'});", btn)
                        time.sleep(0.2)
                        try:
                            btn.click()
                        except Exception:
                            driver.execute_script("arguments[0].click();", btn)
                        print(f"Clicked Apply/Confirm inside iframe[{idx}]")
                        driver.switch_to.default_content()
                        time.sleep(SHORT_SLEEP)
                        wait_for_overlay_to_settle(timeout=OVERLAY_TIMEOUT)
                        return
                finally:
                    try:
                        driver.switch_to.default_content()
                    except Exception:
                        pass
        except Exception:
            pass

        # 5) As a last resort: send END + Enter
        if try_press_enter_fallback():
            wait_for_overlay_to_settle(timeout=OVERLAY_TIMEOUT)
            return

        # 6) Not found -> capture artifacts and raise
        _save_page_source("apply_button_error")
        save_debug("apply_button_error")
        raise Exception("Apply/Confirm button not found after scrolling page/containers, modal, and iframe search.")

    except Exception as e:
        _save_page_source("apply_button_error")
        save_debug("apply_button_error")
        print("Error clicking Apply:", e)
        raise

def confirm_popup(driver):
    """
    Optional: if an 'OK/Yes' inline confirmation appears after Apply.
    """
    try:
        btn = WebDriverWait(driver, 10).until(
            EC.element_to_be_clickable(
                (By.XPATH, "//button[contains(translate(normalize-space(.), 'ABCDEFGHIJKLMNOPQRSTUVWXYZ','abcdefghijklmnopqrstuvwxyz'), 'ok') or contains(translate(normalize-space(.), 'ABCDEFGHIJKLMNOPQRSTUVWXYZ','abcdefghijklmnopqrstuvwxyz'), 'yes')]")
            )
        )
        try:
            btn.click()
        except Exception:
            driver.execute_script("arguments[0].click();", btn)
        time.sleep(SHORT_SLEEP)
        print("Confirmed popup")
    except Exception:
        print("No confirmation popup found (or click failed)")

def wait_for_success_notice(timeout=8 if FAST_MODE else 12):
    """
    Optional: Wait for a success toast/snackbar/alert.
    """
    patterns = ["successfully", "applied", "persisted", "saved", "completed"]
    end = time.time() + timeout
    while time.time() < end:
        try:
            nodes = driver.find_elements(By.XPATH, "//*[contains(@class,'toast') or contains(@class,'snackbar') or contains(@class,'alert') or contains(@class,'message')]")
            for n in nodes:
                if not n.is_displayed():
                    continue
                text = (n.text or "").lower()
                if any(p in text for p in patterns):
                    print("Success notice:", text)
                    return True
        except Exception:
            pass
        time.sleep(0.3)
    return False

# ---------------------- Main flow ----------------------
try:
    print("Using config_dir:", os.path.abspath(config_dir))

    save_debug("login_page")
    try:
        robust_login_flow()
    except Exception as e:
        save_debug("login_failed")
        print("Login failed:", e)
        traceback.print_exc()
        driver.quit()
        raise SystemExit(1)

    # optional short wait for UI stabilization
    try:
        WebDriverWait(driver, 12 if not FAST_MODE else 6).until(
            EC.presence_of_element_located((By.XPATH, "//*[contains(@class,'main') or contains(@id,'app') or contains(@role,'main') or //div[@id='root']]"))
        )
    except Exception:
        pass

    # Scan for AMF files and process
    print("Scanning config_dir for AMF files...")
    for file in os.listdir(config_dir):
        print(f"Found file: {file}")
        if not file.lower().endswith("_amf.json"):
            print(f"Skipping (not AMF): {file}")
            continue
        file_path = os.path.abspath(os.path.join(config_dir, file))
        print(f"Processing AMF file: {file_path}")

        try:
            save_debug(f"before_click_amf_{file}")

            # Steps: Configure -> AMF tab -> click 'amf' entry -> upload file -> Persist -> (confirm) -> [Apply if needed]
            click_nf_tab(driver, "AMF")
            click_nf_entry(driver, "amf")  # IMPORTANT: this reveals the Choose File control

            # Upload; function has robust waits
            upload_config_file(driver, file_path)

            # Import/Persist and inspect native confirm
            click_import(driver)

            # Apply only if Persist wasn't final
            if not PERSIST_IS_FINAL:
                click_apply(driver)
                confirm_popup(driver)
            else:
                print("Skipping Apply due to final Persist confirmation.")

            # Optional success signal
            wait_for_success_notice(timeout=8 if FAST_MODE else 12)

            save_debug(f"completed_amf_{file}")
            print(f"Upload completed for {file}")
        except Exception as e:
            print(f"Failed to upload {file}: {e}")
            traceback.print_exc()
            save_debug(f"error_amf_{file}")
            continue

    print("AMF-only run finished.")

finally:
    try:
        driver.quit()
    except Exception:
        pass
