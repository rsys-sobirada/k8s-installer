#!/usr/bin/env python3
# gui_upload.py  (v4, 2025-09-17)
# AMF-only upload automation with step-by-step screenshots/HTML:
#   Configure -> AMF -> "amf" -> upload JSON -> Persist -> (native confirm) -> [Apply if needed]

import os
import re
import time
import traceback

from selenium import webdriver
from selenium.webdriver.firefox.options import Options
from selenium.webdriver.common.by import By
from selenium.webdriver.common.keys import Keys
from selenium.webdriver.support.ui import WebDriverWait
from selenium.webdriver.support import expected_conditions as EC
from selenium.common.exceptions import TimeoutException

print("gui_upload.py version: v4 (2025-09-17) - step-by-step capture, robust login, persist-final fast path, scroll-apply")

# ---------------------- Config ----------------------
url = "https://172.27.28.193.nip.io/ems/login"
username = "root"
password = "root123"

config_dir = os.environ.get("CONFIG_DIR", "config_files")
debug_dir  = "debug_screenshots"
os.makedirs(debug_dir, exist_ok=True)

# Speed knobs
FAST_MODE        = os.environ.get("FAST_MODE", "0") == "1"
OVERLAY_TIMEOUT  = 6 if FAST_MODE else 12
SHORT_SLEEP      = 0.2 if FAST_MODE else 0.5
SCROLL_ATTEMPTS  = 1 if FAST_MODE else 2

# Capture controls
CAPTURE_ALL_STEPS = os.environ.get("CAPTURE_ALL_STEPS", "0") == "1"
CAPTURE_HTML      = os.environ.get("CAPTURE_HTML", "0") == "1"

# If Persist does the final commit, skip Apply
PERSIST_IS_FINAL = False

# ---------------------- WebDriver setup ----------------------
options = Options()
headless = os.environ.get("HEADLESS", "1")
if headless != "0":
    options.add_argument("--headless")
options.add_argument("--no-sandbox")
options.add_argument("--disable-dev-shm-usage")
options.accept_insecure_certs = True

# Prefer DOMContentLoaded completion
try:
    options.set_capability("pageLoadStrategy", "eager")
except Exception:
    pass

# Safety net: accept unhandled prompts
try:
    options.set_capability("unhandledPromptBehavior", "accept")
except Exception:
    pass

driver = webdriver.Firefox(options=options)

# Tall viewport for footers/action bars
try:
    driver.set_window_size(1500, 2200)
except Exception:
    pass

# ---------------------- Utility/Debug & Capture ----------------------
def wait_document_ready(timeout=25):
    end = time.time() + timeout
    while time.time() < end:
        try:
            if driver.execute_script("return document.readyState") == "complete":
                return True
        except Exception:
            pass
        time.sleep(0.2)
    return False

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

class StepCapture:
    """
    Ordered step-by-step capture of screenshots (+ optional HTML).
    Filenames: <epoch>_S###_<label>.png / .html
    """
    def __init__(self, base_dir):
        self.base_dir = base_dir
        self.counter = 0

    @staticmethod
    def _sanitize(label):
        s = re.sub(r"[^a-zA-Z0-9._-]+", "_", str(label).strip())[:120]
        return s or "step"

    def snap(self, label, html=None):
        # If all-steps capture disabled, only capture when explicitly called by code
        if not CAPTURE_ALL_STEPS and html is None:
            # The code calls snap at important milestones even if CAPTURE_ALL_STEPS=0
            pass

        # Accept any blocking prompt first
        try:
            handle_native_alerts(timeout=1, accept=True)
        except Exception:
            pass

        self.counter += 1
        prefix = f"{int(time.time())}_S{self.counter:03d}_{self._sanitize(label)}"
        png = os.path.join(self.base_dir, f"{prefix}.png")
        try:
            driver.save_screenshot(png)
            print(f"[CAPTURE] {png}")
        except Exception as e:
            print(f"[CAPTURE-ERR] screenshot failed for {png}: {e}")
            if handle_native_alerts(timeout=2, accept=True):
                time.sleep(0.2)
                try:
                    driver.save_screenshot(png)
                    print(f"[CAPTURE] (retry) {png}")
                except Exception as e2:
                    print(f"[CAPTURE-ERR] retry failed for {png}: {e2}")

        if html is None:
            html = CAPTURE_HTML
        if html:
            htm = os.path.join(self.base_dir, f"{prefix}.html")
            try:
                with open(htm, "w", encoding="utf-8") as fh:
                    fh.write(driver.page_source)
                print(f"[CAPTURE] {htm}")
            except Exception as e:
                print(f"[CAPTURE-ERR] html failed for {htm}: {e}")

# global step capture instance
step = StepCapture(debug_dir)

# For backward compat: save_debug delegates to step.snap (no HTML by default)
def save_debug(name):
    step.snap(name, html=False)

def _save_page_source(name):
    step.snap(f"{name}_pagesrc", html=True)

# ---------------------- Login helpers ----------------------
def handle_firefox_cert_interstitial(max_tries=2):
    for _ in range(max_tries):
        try:
            cur = driver.current_url or ""
        except Exception:
            cur = ""
        if "about:certerror" in cur or "certerror" in cur.lower():
            print("Detected Firefox certificate interstitial; accepting risk...")
            try:
                try:
                    driver.find_element(By.ID, "advancedButton").click()
                    time.sleep(0.3)
                except Exception:
                    pass
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
        u = None
        for xp in user_xps:
            u = _first_visible(driver.find_elements(By.XPATH, xp))
            if u: break
        p = _first_visible(driver.find_elements(By.XPATH, pass_xps[0])) or \
            _first_visible(driver.find_elements(By.XPATH, pass_xps[1]))
        b = None
        for xp in login_btn_xps:
            b = _first_visible(driver.find_elements(By.XPATH, xp))
            if b: break
        return (u, p, b)

    while time.time() < end:
        try:
            u, p, b = find_fields_in_context()
            if u and p:
                return (u, p, b)
            def inner():
                u2, p2, b2 = find_fields_in_context()
                return _first_visible([u2, p2, b2])
            el, fr = _find_in_iframes(inner)
            if el:
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
    step.snap("S_LOGIN_page_open", html=True)
    wait_document_ready(timeout=25)
    handle_firefox_cert_interstitial(max_tries=2)
    step.snap("S_LOGIN_after_interstitial", html=True)

    try:
        print("Login page URL:", driver.current_url)
        print("Login page title:", driver.title)
    except Exception:
        pass

    u, p, btn = locate_login_fields(timeout=30)
    step.snap("S_LOGIN_fields_located", html=True)
    if not u or not p:
        step.snap("S_LOGIN_failed_no_fields", html=True)
        raise TimeoutException("Could not find username/password fields on the login page")

    try: u.clear()
    except Exception: pass
    u.send_keys(username)
    step.snap("S_LOGIN_username_filled", html=True)

    try: p.clear()
    except Exception: pass
    p.send_keys(password)
    step.snap("S_LOGIN_password_filled", html=False)

    if btn:
        try: btn.click()
        except Exception: driver.execute_script("arguments[0].click();", btn)
        step.snap("S_LOGIN_clicked_button", html=True)
    else:
        p.send_keys("\n")
        step.snap("S_LOGIN_enter_pressed", html=True)

    time.sleep(2.0)
    step.snap("S_LOGIN_after_login", html=True)

# ---------------------- Generic element finder ----------------------
def find_element_by_text_any(tag_text, timeout=6):
    lower_text = tag_text.lower()
    xpaths = [
        f"//*[contains(translate(normalize-space(.), 'ABCDEFGHIJKLMNOPQRSTUVWXYZ', 'abcdefghijklmnopqrstuvwxyz'), '{lower_text}')]",
        f"//*[contains(translate(text(), 'ABCDEFGHIJKLMNOPQRSTUVWXYZ', 'abcdefghijklmnopqrstuvwxyz'), '{lower_text}')]",
    ]
    for xp in xpaths:
        try:
            elem = WebDriverWait(driver, timeout).until(EC.presence_of_element_located((By.XPATH, xp)))
            return elem
        except Exception:
            pass

    candidate_tags = ["a", "button", "div", "span", "li", "label", "td", "th", "*"]
    try:
        for tag in candidate_tags:
            for e in driver.find_elements(By.TAG_NAME, tag):
                try:
                    text = (e.text or "").strip()
                    if text and lower_text in text.lower():
                        return e
                except Exception:
                    continue
    except Exception:
        pass

    attrs = ["title", "aria-label", "data-testid", "data-test", "alt", "role", "placeholder", "id", "class", "name"]
    try:
        for e in driver.find_elements(By.XPATH, "//*"):
            try:
                for a in attrs:
                    val = e.get_attribute(a)
                    if val and lower_text in val.lower():
                        return e
            except Exception:
                continue
    except Exception:
        pass

    try:
        iframes = driver.find_elements(By.TAG_NAME, "iframe")
        for idx, fr in enumerate(iframes):
            try:
                driver.switch_to.frame(fr)
                for xp in xpaths:
                    try:
                        elem = WebDriverWait(driver, 1).until(EC.presence_of_element_located((By.XPATH, xp)))
                        driver.switch_to.default_content()
                        return elem
                    except Exception:
                        pass
                for e in driver.find_elements(By.XPATH, "//*"):
                    for a in attrs:
                        try:
                            val = e.get_attribute(a)
                            if val and lower_text in val.lower():
                                driver.switch_to.default_content()
                                return e
                        except Exception:
                            continue
            except Exception:
                pass
            finally:
                try: driver.switch_to.default_content()
                except Exception: pass
    except Exception:
        pass

    _save_page_source(f"no_elem_{tag_text}")
    raise Exception(f"Element containing text '{tag_text}' not found.")

# ---------------------- Click helpers ----------------------
def click_element_via_js(elem, label="click_js"):
    driver.execute_script("arguments[0].scrollIntoView({block:'center', inline:'center'});", elem)
    step.snap(f"{label}_before", html=True)
    driver.execute_script("arguments[0].click();", elem)
    time.sleep(SHORT_SLEEP)
    step.snap(f"{label}_after", html=True)

def open_configure_menu():
    print("Attempting to open 'Configure' menu...")
    step.snap("S_NAV_before_open_configure", html=True)
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
            step.snap("S_NAV_after_open_configure", html=True)
            time.sleep(0.3 if FAST_MODE else 1.0)
            return
        except Exception:
            continue
    el = find_element_by_text_any("Configure", timeout=3)
    try: el.click()
    except Exception: driver.execute_script("arguments[0].click();", el)
    print("Clicked 'Configure' (fallback)")
    step.snap("S_NAV_after_open_configure_fallback", html=True)
    time.sleep(0.3 if FAST_MODE else 1.0)

def click_nf_tab(driver, nf_name):
    try:
        try: open_configure_menu()
        except Exception: print("Configure open failed; continuing (maybe already open).")
        print(f"Looking for NF tab '{nf_name}'")
        step.snap("S_NAV_before_click_tab", html=True)
        elem = find_element_by_text_any(nf_name, timeout=6)
        driver.execute_script("arguments[0].scrollIntoView({block:'center'});", elem)
        time.sleep(SHORT_SLEEP)
        try: elem.click()
        except Exception: driver.execute_script("arguments[0].click();", elem)
        time.sleep(SHORT_SLEEP)
        step.snap("S_NAV_after_click_tab", html=True)
        print(f"Clicked NF tab '{nf_name}'")
    except Exception as e:
        _save_page_source(f"click_lookup_failed_{nf_name}")
        step.snap(f"S_ERR_click_tab_{nf_name}", html=True)
        print(f"Error clicking NF tab '{nf_name}': {e}")
        raise

def click_nf_entry(driver, entry_text):
    try:
        print(f"Looking for NF entry '{entry_text}' (inside NF panel)...")
        step.snap("S_NAV_before_click_nf_entry", html=True)
        elem = find_element_by_text_any(entry_text, timeout=8)
        driver.execute_script("arguments[0].scrollIntoView({block:'center'});", elem)
        time.sleep(SHORT_SLEEP)
        try: elem.click()
        except Exception: driver.execute_script("arguments[0].click();", elem)
        time.sleep(SHORT_SLEEP)
        step.snap("S_NAV_after_click_nf_entry", html=True)
        print(f"Clicked NF entry '{entry_text}'")
    except Exception as e:
        _save_page_source(f"nf_entry_not_found_{entry_text}")
        step.snap(f"S_ERR_nf_entry_{entry_text}", html=True)
        print(f"Error clicking NF entry '{entry_text}': {e}")
        raise

# ---------------------- Upload helpers ----------------------

def select_amf_from_left_panel():
    """
    Try to emulate the left panel: click 'Add' if present (blue button),
    then click the left-side entry 'amf' so the panel matches the screenshot.
    This is intentionally conservative: it will not fail if controls are absent.
    """
    try:
        # Ensure Configure is open (best-effort)
        try:
            open_configure_menu()
        except Exception:
            pass
        step.snap("S_LEFT_before_select_amf", html=True)
        # Try to find a visible 'Add' button in the left panel
        add_xps = [
            "//button[contains(translate(normalize-space(.),'ABCDEFGHIJKLMNOPQRSTUVWXYZ','abcdefghijklmnopqrstuvwxyz'),'add')]",
            "//*[contains(@class,'add') and contains(translate(normalize-space(.),'ABCDEFGHIJKLMNOPQRSTUVWXYZ','abcdefghijklmnopqrstuvwxyz'),'add')]",
            "//div[contains(normalize-space(.),'Add') and contains(@class,'panel')]",
        ]
        for xp in add_xps:
            try:
                btn = WebDriverWait(driver, 2).until(EC.element_to_be_clickable((By.XPATH, xp)))
                if btn and btn.is_displayed():
                    try:
                        driver.execute_script("arguments[0].scrollIntoView({block:'center', inline:'center'});", btn)
                        btn.click()
                    except Exception:
                        driver.execute_script("arguments[0].click();", btn)
                    step.snap("S_LEFT_after_click_add", html=True)
                    time.sleep(0.3)
                    break
            except Exception:
                continue

        # Now find the left-panel item labeled 'amf' (exact word match preference)
        try:
            amf_elem = None
            candidates = driver.find_elements(By.XPATH, "//*[translate(normalize-space(.),'ABCDEFGHIJKLMNOPQRSTUVWXYZ','abcdefghijklmnopqrstuvwxyz')='amf']")
            amf_elem = _first_visible(candidates)
            if not amf_elem:
                # fallback: contains 'amf'
                amf_elem = find_element_by_text_any(" amf ")
            if amf_elem:
                driver.execute_script("arguments[0].scrollIntoView({block:'center'});", amf_elem)
                try: amf_elem.click()
                except Exception: driver.execute_script("arguments[0].click();", amf_elem)
                step.snap("S_LEFT_after_click_amf", html=True)
            else:
                step.snap("S_LEFT_no_amf_found", html=True)
        except Exception as e:
            step.snap("S_LEFT_amf_click_error", html=True)
            print("Error selecting left-panel amf:", e)
    except Exception as e:
        print("select_amf_from_left_panel encountered error:", e)

def upload_config_file(driver, file_path):
    print(f"Attempting to upload file: {file_path}")
    step.snap("S_UPLOAD_before", html=True)
    selectors = [
        "//input[@type='file']",
        "//input[contains(@class,'file') and @type='file']",
        "//input[contains(@id,'file') and @type='file']",
        "//input[contains(@name,'file') and @type='file']",
        "//input[contains(@data-test,'file') and @type='file']",
    ]
    time.sleep(SHORT_SLEEP)

    for sel in selectors:
        try:
            file_input = WebDriverWait(driver, 12).until(EC.presence_of_element_located((By.XPATH, sel)))
            driver.execute_script("arguments[0].style.display='block'; arguments[0].style.visibility='visible'; arguments[0].style.height='1px';", file_input)
            file_input.send_keys(file_path)
            print(f"Sent file path via selector: {sel}")
            step.snap("S_UPLOAD_after_sendkeys", html=True)
            time.sleep(SHORT_SLEEP)
            return
        except Exception:
            continue

    try:
        els = driver.find_elements(By.XPATH, "//input[@type='file']")
        if els:
            for e in els:
                try:
                    driver.execute_script("arguments[0].style.display='block'; arguments[0].style.visibility='visible';", e)
                    e.send_keys(file_path)
                    print("Sent file path to one of the inputs")
                    step.snap("S_UPLOAD_after_sendkeys_findelements", html=True)
                    time.sleep(SHORT_SLEEP)
                    return
                except Exception:
                    continue
    except Exception:
        pass

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
            step.snap("S_UPLOAD_before_choose_click", html=True)
            try: btn.click()
            except Exception: driver.execute_script("arguments[0].click();", btn)
            time.sleep(0.3)
            try:
                file_input = WebDriverWait(driver, 3).until(EC.presence_of_element_located((By.XPATH, "//input[@type='file']")))
                driver.execute_script("arguments[0].style.display='block'; arguments[0].style.visibility='visible';", file_input)
                file_input.send_keys(file_path)
                print("Sent file path after clicking choose/browse")
                step.snap("S_UPLOAD_after_choose_sendkeys", html=True)
                time.sleep(SHORT_SLEEP)
                return
            except Exception:
                pass
        except Exception:
            continue

    try:
        iframes = driver.find_elements(By.TAG_NAME, "iframe")
        print(f"Scanning {len(iframes)} iframe(s) for input[type=file]")
        step.snap("S_UPLOAD_scan_iframes", html=True)
        for idx, fr in enumerate(iframes):
            try:
                driver.switch_to.frame(fr)
                found = False
                for sel in selectors:
                    try:
                        file_input = driver.find_element(By.XPATH, sel)
                        driver.execute_script("arguments[0].style.display='block'; arguments[0].style.visibility='visible';", file_input)
                        file_input.send_keys(file_path)
                        print(f"Sent file path in iframe[{idx}] via {sel}")
                        found = True
                        step.snap(f"S_UPLOAD_iframe{idx}_after_sendkeys", html=True)
                        time.sleep(SHORT_SLEEP)
                        break
                    except Exception:
                        continue
                driver.switch_to.default_content()
                if found:
                    return
            except Exception:
                try: driver.switch_to.default_content()
                except Exception: pass
                continue
    except Exception:
        pass

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
        step.snap("S_UPLOAD_before_injected_input", html=True)
        tmp.send_keys(file_path)
        print("Injected temporary input and sent file path.")
        step.snap("S_UPLOAD_after_injected_input", html=True)
        time.sleep(SHORT_SLEEP)
        return
    except Exception as e:
        print("Failed to inject/use temporary input:", e)

    _save_page_source("file_input_error")
    step.snap("S_ERR_upload_no_file_input", html=True)
    raise Exception("Could not locate file input element to upload the config file.")

# ---------------------- Import / Apply helpers ----------------------
def click_import(driver):
    """
    Click 'Persist Configurations' / Import-like action.
    Accepts native confirm and sets PERSIST_IS_FINAL if dialog implies final commit.
    """
    global PERSIST_IS_FINAL
    print("Looking for 'Persist Configurations' / Import button...")
    texts = ["persist configurations", "persist", "import", "upload", "save configuration", "save"]
    for t in texts:
        try:
            btn = WebDriverWait(driver, 12).until(
                EC.element_to_be_clickable((By.XPATH, f"//button[contains(translate(normalize-space(.), 'ABCDEFGHIJKLMNOPQRSTUVWXYZ','abcdefghijklmnopqrstuvwxyz'), '{t}')]"))
            )
            step.snap("S_PERSIST_before_click", html=True)
            try: btn.click()
            except Exception: driver.execute_script("arguments[0].click();", btn)
            print(f"Clicked import-like button: '{t}'")
            step.snap("S_PERSIST_after_click", html=True)

            alert_text = handle_native_alerts(timeout=8, accept=True)
            if alert_text:
                step.snap("S_PERSIST_after_native_confirm", html=True)
                print("Confirmed 'Persist Configurations' native dialog")
                lt = alert_text.lower()
                if "all nfs" in lt or ("running" in lt and "startup" in lt):
                    PERSIST_IS_FINAL = True
                    print("Persist appears final (no Apply needed).")
                    step.snap("S_PERSIST_marked_final", html=True)
            return
        except Exception:
            continue
    step.snap("S_ERR_persist_btn_not_found", html=True)
    raise Exception("No import/persist/upload button found")

def scroll_page(step_ratio=0.85, attempts=6, direction="down"):
    dy = "Math.floor(window.innerHeight*arguments[0])"
    for _ in range(attempts):
        if direction == "down":
            driver.execute_script(f"window.scrollBy(0, {dy});", step_ratio)
        else:
            driver.execute_script(f"window.scrollBy(0, -{dy});", step_ratio)
        time.sleep(0.2)

def scroll_all_scrollables_to_bottom():
    xps = ["//*[contains(@class,'scroll') or contains(@class,'content') or contains(@class,'container') or contains(@class,'panel') or contains(@style,'overflow')]"]
    for xp in xps:
        try:
            for el in driver.find_elements(By.XPATH, xp):
                try:
                    is_scrollable = driver.execute_script("return arguments[0].scrollHeight > arguments[0].clientHeight;", el)
                    if is_scrollable and el.is_displayed():
                        driver.execute_script("arguments[0].scrollTop = arguments[0].scrollHeight;", el)
                        time.sleep(0.1)
                except Exception:
                    continue
        except Exception:
            continue

def _find_modal_roots():
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

def _find_clickable_in_context(root, xpath, timeout=6):
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
    root = context if context is not None else driver
    btn_texts = ["apply", "apply changes", "confirm", "proceed", "ok", "yes", "submit", "update", "save", "continue"]
    footer_xps = [
        ".//*[contains(@class,'action') or contains(@class,'footer') or contains(@class,'button-bar') or contains(@class,'btn-toolbar')]" if context is not None
        else "//*[contains(@class,'action') or contains(@class,'footer') or contains(@class,'button-bar') or contains(@class,'btn-toolbar')]"
    ]
    try:
        footers = []
        for xp in footer_xps:
            try: footers.extend(root.find_elements(By.XPATH, xp))
            except Exception: continue
        footers = [f for f in footers if f.is_displayed()]
        for ftr in footers:
            for t in btn_texts:
                btn = _find_clickable_in_context(
                    ftr,
                    ".//*[self::button or self::a or self::span or self::div]"
                    f"[contains(translate(normalize-space(.), 'ABCDEFGHIJKLMNOPQRSTUVWXYZ','abcdefghijklmnopqrstuvwxyz'), '{t}')]",
                    timeout=2
                )
                if btn:
                    return btn
    except Exception:
        pass

    for t in btn_texts:
        try:
            btn = WebDriverWait(driver, timeout).until(
                EC.element_to_be_clickable((
                    By.XPATH,
                    "//*[self::button or self::a or self::span or self::div]"
                    f"[contains(translate(normalize-space(.), 'ABCDEFGHIJKLMNOPQRSTUVWXYZ','abcdefghijklmnopqrstuvwxyz'), '{t}')]"
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
                    if any(e.is_displayed() for e in driver.find_elements(By.XPATH, xp)):
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
    try:
        handle_native_alerts(timeout=2, accept=True)
        step.snap("S_APPLY_start", html=True)
        wait_for_overlay_to_settle(timeout=OVERLAY_TIMEOUT)
        time.sleep(SHORT_SLEEP)

        scroll_page(step_ratio=1.0, attempts=SCROLL_ATTEMPTS, direction="down")
        scroll_all_scrollables_to_bottom()
        step.snap("S_APPLY_after_scroll", html=True)
        time.sleep(0.2)

        btn = find_apply_like_button(timeout=6 if FAST_MODE else 10)
        if btn:
            driver.execute_script("arguments[0].scrollIntoView({block:'center'});", btn)
            step.snap("S_APPLY_before_click", html=True)
            time.sleep(0.2)
            try: btn.click()
            except Exception: driver.execute_script("arguments[0].click();", btn)
            print("Clicked Apply/Confirm in page body after scrolling")
            time.sleep(SHORT_SLEEP)
            wait_for_overlay_to_settle(timeout=OVERLAY_TIMEOUT)
            step.snap("S_APPLY_after_click", html=True)
            return

        for m in _find_modal_roots():
            # Tick required checkboxes if present
            try:
                for lbl in ["i understand", "acknowledge", "i agree", "confirm", "overwrite", "force", "accept", "proceed"]:
                    try:
                        lab = m.find_element(By.XPATH, f".//label[contains(translate(normalize-space(.), 'ABCDEFGHIJKLMNOPQRSTUVWXYZ','abcdefghijklmnopqrstuvwxyz'), '{lbl}')]")
                        for cb in m.find_elements(By.XPATH, ".//input[@type='checkbox']"):
                            try:
                                if not cb.is_selected() and cb.is_displayed():
                                    driver.execute_script("arguments[0].scrollIntoView({block:'center'});", cb)
                                    time.sleep(0.1)
                                    try: cb.click()
                                    except Exception: driver.execute_script("arguments[0].click();", cb)
                                    time.sleep(0.2)
                                    break
                            except Exception:
                                continue
                    except Exception:
                        continue
            except Exception:
                pass

            btn = find_apply_like_button(context=m, timeout=5)
            if btn:
                driver.execute_script("arguments[0].scrollIntoView({block:'center'});", btn)
                step.snap("S_APPLY_modal_before_click", html=True)
                time.sleep(0.2)
                try: btn.click()
                except Exception: driver.execute_script("arguments[0].click();", btn)
                print("Clicked Apply/Confirm inside modal")
                time.sleep(SHORT_SLEEP)
                wait_for_overlay_to_settle(timeout=OVERLAY_TIMEOUT)
                step.snap("S_APPLY_modal_after_click", html=True)
                return

        try:
            iframes = driver.find_elements(By.TAG_NAME, "iframe")
            for idx, fr in enumerate(iframes):
                try:
                    driver.switch_to.frame(fr)
                    btn = find_apply_like_button(timeout=4)
                    if btn:
                        driver.execute_script("arguments[0].scrollIntoView({block:'center'});", btn)
                        step.snap(f"S_APPLY_iframe{idx}_before_click", html=True)
                        time.sleep(0.2)
                        try: btn.click()
                        except Exception: driver.execute_script("arguments[0].click();", btn)
                        print(f"Clicked Apply/Confirm inside iframe[{idx}]")
                        driver.switch_to.default_content()
                        time.sleep(SHORT_SLEEP)
                        wait_for_overlay_to_settle(timeout=OVERLAY_TIMEOUT)
                        step.snap(f"S_APPLY_iframe{idx}_after_click", html=True)
                        return
                finally:
                    try: driver.switch_to.default_content()
                    except Exception: pass
        except Exception:
            pass

        if try_press_enter_fallback():
            wait_for_overlay_to_settle(timeout=OVERLAY_TIMEOUT)
            step.snap("S_APPLY_after_enter_fallback", html=True)
            return

        _save_page_source("apply_button_error")
        step.snap("S_ERR_apply_btn_not_found", html=True)
        raise Exception("Apply/Confirm button not found after scrolling page/containers, modal, and iframe search.")

    except Exception as e:
        _save_page_source("apply_button_error")
        step.snap("S_ERR_apply_exception", html=True)
        print("Error clicking Apply:", e)
        raise

def confirm_popup(driver):
    try:
        btn = WebDriverWait(driver, 10).until(
            EC.element_to_be_clickable((By.XPATH, "//button[contains(translate(normalize-space(.), 'ABCDEFGHIJKLMNOPQRSTUVWXYZ','abcdefghijklmnopqrstuvwxyz'), 'ok') or contains(translate(normalize-space(.), 'ABCDEFGHIJKLMNOPQRSTUVWXYZ','abcdefghijklmnopqrstuvwxyz'), 'yes')]"))
        )
        step.snap("S_CONFIRM_before_click", html=True)
        try: btn.click()
        except Exception: driver.execute_script("arguments[0].click();", btn)
        time.sleep(SHORT_SLEEP)
        step.snap("S_CONFIRM_after_click", html=True)
        print("Confirmed popup")
    except Exception:
        step.snap("S_CONFIRM_not_found", html=True)
        print("No confirmation popup found (or click failed)")

def wait_for_success_notice(timeout=8 if FAST_MODE else 12):
    patterns = ["successfully", "applied", "persisted", "saved", "completed"]
    end = time.time() + timeout
    while time.time() < end:
        try:
            nodes = driver.find_elements(By.XPATH, "//*[contains(@class,'toast') or contains(@class,'snackbar') or contains(@class,'alert') or contains(@class,'message')]")
            for n in nodes:
                if not n.is_displayed(): continue
                text = (n.text or "").lower()
                if any(p in text for p in patterns):
                    print("Success notice:", text)
                    step.snap("S_SUCCESS_notice_detected", html=True)
                    return True
        except Exception:
            pass
        time.sleep(0.3)
    step.snap("S_SUCCESS_notice_timeout", html=True)
    return False

# ---------------------- Main flow ----------------------
try:
    print("Using config_dir:", os.path.abspath(config_dir))

    # LOGIN
    robust_login_flow()

    try:
        WebDriverWait(driver, 12 if not FAST_MODE else 6).until(
            EC.presence_of_element_located((By.XPATH, "//*[contains(@class,'main') or contains(@id,'app') or contains(@role,'main') or //div[@id='root']]"))
        )
    except Exception:
        pass
    step.snap("S_HOME_after_login_land", html=True)

    # PROCESS AMF FILES
    print("Scanning config_dir for AMF files...")
    for file in os.listdir(config_dir):
        print(f"Found file: {file}")
        if not file.lower().endswith("_amf.json"):
            print(f"Skipping (not AMF): {file}")
            continue
        file_path = os.path.abspath(os.path.join(config_dir, file))
        print(f"Processing AMF file: {file_path}")

        try:
            step.snap(f"S_TASK_{file}_start", html=True)

            # Navigate
            click_nf_tab(driver, "AMF")
            
            # NEW: attempt left-panel selection (click Add then left "amf" entry) to match screenshot
            select_amf_from_left_panel()
            click_nf_entry(driver, "amf")

            # Upload
            upload_config_file(driver, file_path)

            # Persist & confirm
            click_import(driver)

            # Apply only if needed
            if not PERSIST_IS_FINAL:
                click_apply(driver)
                confirm_popup(driver)
            else:
                print("Skipping Apply due to final Persist confirmation.")
                step.snap("S_APPLY_skipped_persist_final", html=True)

            # Success indicator (best effort)
            wait_for_success_notice(timeout=8 if FAST_MODE else 12)

            step.snap(f"S_TASK_{file}_done", html=True)
            print(f"Upload completed for {file}")
        except Exception as e:
            print(f"Failed to upload {file}: {e}")
            traceback.print_exc()
            step.snap(f"S_TASK_{file}_error", html=True)
            continue

    print("AMF-only run finished.")
    step.snap("S_FLOW_complete", html=True)

finally:
    try:
        driver.quit()
    except Exception:
        pass
