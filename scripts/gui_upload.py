#!/usr/bin/env python3
# scripts/gui_upload.py
# AMF-only upload automation: Configure -> AMF -> amf entry -> upload JSON
#
# Usage:
#   CONFIG_DIR=/path/to/configs ./venv/bin/python scripts/gui_upload.py
# Defaults to ./config_files if CONFIG_DIR not set.

from selenium import webdriver
from selenium.webdriver.firefox.options import Options
from selenium.webdriver.common.by import By
from selenium.webdriver.support.ui import WebDriverWait
from selenium.webdriver.support import expected_conditions as EC
import time, os, traceback

# -------- Config ----------
url = "https://172.27.28.193.nip.io/ems/login"
username = "root"
password = "root123"

config_dir = os.environ.get("CONFIG_DIR", "config_files")
debug_dir = "debug_screenshots"
os.makedirs(debug_dir, exist_ok=True)

# Only AMF for this run
suffix_tab_map = {"_amf": "AMF"}

# -------- WebDriver setup ----------
options = Options()
options.add_argument("--headless")
options.add_argument("--no-sandbox")
options.add_argument("--disable-dev-shm-usage")
options.accept_insecure_certs = True

driver = webdriver.Firefox(options=options)

# -------- Debug helpers ----------
def save_debug(name):
    path = os.path.join(debug_dir, f"{int(time.time())}_{name}.png")
    try:
        driver.save_screenshot(path)
        print(f"Saved screenshot: {path}")
    except Exception as e:
        print(f"Failed to save screenshot {path}: {e}")

def _save_page_source(name):
    path = os.path.join(debug_dir, f"{int(time.time())}_{name}.html")
    try:
        with open(path, "w", encoding="utf-8") as fh:
            fh.write(driver.page_source)
        print(f"Saved page source: {path}")
    except Exception as e:
        print(f"Failed to save page source {path}: {e}")

# -------- Robust finder (text/attributes/iframes) ----------
def find_element_by_text_any(tag_text, timeout=6):
    """
    Find an element containing tag_text (case-insensitive) using several strategies.
    Raises Exception if not found and saves page source for debugging.
    """
    lower_text = tag_text.lower()
    xpaths = [
        f"//*[contains(translate(normalize-space(.), 'ABCDEFGHIJKLMNOPQRSTUVWXYZ', 'abcdefghijklmnopqrstuvwxyz'), '{lower_text}')]",
        f"//*[contains(translate(text(), 'ABCDEFGHIJKLMNOPQRSTUVWXYZ', 'abcdefghijklmnopqrstuvwxyz'), '{lower_text}')]",
    ]

    # 1) try quick XPath attempts
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

    # not found: save page source and raise
    _save_page_source(f"no_elem_{tag_text}")
    raise Exception(f"Element containing text '{tag_text}' not found using candidate strategies.")

# -------- Click helpers ----------
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
            time.sleep(1.2)
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
        time.sleep(1.2)
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
            time.sleep(0.4)
        except Exception:
            pass
        try:
            elem.click()
            time.sleep(0.6)
        except Exception:
            driver.execute_script("arguments[0].click();", elem)
            time.sleep(0.6)
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
            time.sleep(0.3)
        except Exception:
            pass
        try:
            elem.click()
            time.sleep(0.6)
        except Exception:
            driver.execute_script("arguments[0].click();", elem)
            time.sleep(0.6)
        print(f"Clicked NF entry '{entry_text}'")
    except Exception as e:
        _save_page_source(f"nf_entry_not_found_{entry_text}")
        print(f"Error clicking NF entry '{entry_text}': {e}")
        raise

def click_add_button(driver):
    """Click a generic 'Add' button (keeps for safety though not needed in amf path)."""
    try:
        xp = "//button[contains(translate(normalize-space(.), 'ABCDEFGHIJKLMNOPQRSTUVWXYZ','abcdefghijklmnopqrstuvwxyz'), 'add')]"
        btn = WebDriverWait(driver, 8).until(EC.element_to_be_clickable((By.XPATH, xp)))
        try:
            btn.click()
        except Exception:
            driver.execute_script("arguments[0].click();", btn)
        time.sleep(0.6)
        print("Clicked Add button")
    except Exception as e:
        _save_page_source("add_button_not_found")
        print("Add button not found:", e)
        raise

# -------- Robust upload function ----------
def upload_config_file(driver, file_path):
    """
    Robust upload:
      - waits for input[type=file] with extended timeout
      - tries multiple selectors
      - clicks 'Choose/Browse' triggers and searches in iframes
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

    # give UI some time to render
    time.sleep(0.6)

    # 1) try with a larger wait (race conditions)
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
            time.sleep(0.5)
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
                    time.sleep(0.5)
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
            time.sleep(0.6)
            try:
                file_input = WebDriverWait(driver, 3).until(EC.presence_of_element_located((By.XPATH, "//input[@type='file']")))
                driver.execute_script("arguments[0].style.display='block'; arguments[0].style.visibility='visible';", file_input)
                file_input.send_keys(file_path)
                print("Sent file path after clicking choose/browse")
                time.sleep(0.5)
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
                        time.sleep(0.5)
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
        time.sleep(0.5)
        return
    except Exception as e:
        print("Failed to inject/use temporary input:", e)

    # nothing worked — save artifacts and raise
    _save_page_source("file_input_error")
    save_debug("file_input_error")
    raise Exception("Could not locate file input element to upload the config file.")

# -------- Import / Apply / Confirm ----------
def click_import(driver):
    try:
        print("Looking for 'Persist Configurations' button...")
        btn = WebDriverWait(driver, 12).until(
            EC.element_to_be_clickable((
                By.XPATH,
                "//button[contains(translate(normalize-space(.), 'ABCDEFGHIJKLMNOPQRSTUVWXYZ','abcdefghijklmnopqrstuvwxyz'),'persist configurations')]"
            ))
        )
        btn.click()
        print("Clicked 'Persist Configurations' button successfully")
    except Exception as e:
        print(f"Error clicking 'Persist Configurations': {e}")
        driver.save_screenshot(f"debug_screenshots/{int(time.time())}_error_persist_config.png")
        raise


def click_apply(driver):
    try:
        # Handle alert before locating the button
        try:
            alert = driver.switch_to.alert
            print("Pre-Apply Alert text:", alert.text)
            alert.accept()
            print("Pre-Apply Alert accepted")
            time.sleep(0.5)
        except NoAlertPresentException:
            pass

        try:
            btn = WebDriverWait(driver, 12).until(
                EC.element_to_be_clickable((By.XPATH, "//button[contains(translate(normalize-space(.), 'ABCDEFGHIJKLMNOPQRSTUVWXYZ','abcdefghijklmnopqrstuvwxyz'), 'apply')]"))
            )
        except UnexpectedAlertPresentException:
            try:
                alert = driver.switch_to.alert
                print("Alert during Apply button wait:", alert.text)
                alert.accept()
                print("Alert accepted during Apply button wait")
                time.sleep(0.5)
                btn = WebDriverWait(driver, 12).until(
                    EC.element_to_be_clickable((By.XPATH, "//button[contains(translate(normalize-space(.), 'ABCDEFGHIJKLMNOPQRSTUVWXYZ','abcdefghijklmnopqrstuvwxyz'), 'apply')]"))
                )
            except Exception as e:
                print("Failed to handle alert during Apply button wait:", e)
                raise

        try:
            btn.click()
        except Exception:
            driver.execute_script("arguments[0].click();", btn)
        time.sleep(0.6)
        print("Clicked Apply")

        # Handle alert after clicking Apply
        try:
            alert = driver.switch_to.alert
            print("Post-Apply Alert text:", alert.text)
            alert.accept()
            print("Post-Apply Alert accepted")
        except NoAlertPresentException:
            print("No alert present after Apply")

    except Exception as e:
        _save_page_source("apply_button_error")
        print("Error clicking Apply:", e)
        raise

def confirm_popup(driver):
    try:
        btn = WebDriverWait(driver, 10).until(
            EC.element_to_be_clickable((By.XPATH, "//button[contains(translate(normalize-space(.), 'ABCDEFGHIJKLMNOPQRSTUVWXYZ','abcdefghijklmnopqrstuvwxyz'), 'ok') or contains(translate(normalize-space(.), 'ABCDEFGHIJKLMNOPQRSTUVWXYZ','abcdefghijklmnopqrstuvwxyz'), 'yes')]"))
        )
        try:
            btn.click()
        except Exception:
            driver.execute_script("arguments[0].click();", btn)
        time.sleep(0.5)
        print("Confirmed popup")
    except Exception:
        print("No confirmation popup found (or click failed)")

# -------- Main flow ----------
try:
    print("Using config_dir:", os.path.abspath(config_dir))
    driver.get(url)
    time.sleep(2)
    save_debug("login_page")

    # Login
    try:
        WebDriverWait(driver, 20).until(
            EC.presence_of_element_located((By.XPATH, "//input[@placeholder='Enter your username' or @name='username' or @id='username']"))
        )
        # username
        try:
            driver.find_element(By.XPATH, "//input[@placeholder='Enter your username']").send_keys(username)
        except Exception:
            try:
                driver.find_element(By.XPATH, "//input[@name='username']").send_keys(username)
            except Exception:
                driver.find_element(By.XPATH, "//input[@id='username']").send_keys(username)
        # password
        try:
            driver.find_element(By.XPATH, "//input[@placeholder='Enter your password']").send_keys(password)
        except Exception:
            try:
                driver.find_element(By.XPATH, "//input[@name='password']").send_keys(password)
            except Exception:
                driver.find_element(By.XPATH, "//input[@id='password']").send_keys(password)

        # click login
        login_btn_xps = [
            "//button[contains(translate(normalize-space(.), 'ABCDEFGHIJKLMNOPQRSTUVWXYZ','abcdefghijklmnopqrstuvwxyz'), 'login')]",
            "//input[@type='submit' and contains(translate(@value,'ABCDEFGHIJKLMNOPQRSTUVWXYZ','abcdefghijklmnopqrstuvwxyz'),'login')]"
        ]
        clicked = False
        for xp in login_btn_xps:
            try:
                login_btn = WebDriverWait(driver, 6).until(EC.element_to_be_clickable((By.XPATH, xp)))
                try:
                    login_btn.click()
                except Exception:
                    driver.execute_script("arguments[0].click();", login_btn)
                clicked = True
                break
            except Exception:
                continue
        if not clicked:
            try:
                pwd = driver.find_element(By.XPATH, "//input[@type='password']")
                pwd.send_keys("\n")
            except Exception:
                pass

        time.sleep(3)
        save_debug("after_login")
    except Exception as e:
        save_debug("login_failed")
        print("Login failed:", e)
        traceback.print_exc()
        driver.quit()
        raise SystemExit(1)

    # optional short wait for UI stabilization
    try:
        WebDriverWait(driver, 12).until(
            EC.presence_of_element_located((By.XPATH, "//*[contains(@class,'main') or contains(@id,'app') or contains(@role,'main') or //div[@id='root']]"))
        )
    except Exception:
        pass

    # scan for AMF files and process
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
            # Steps: configure -> AMF tab -> click 'amf' entry -> upload file -> import/apply/confirm
            click_nf_tab(driver, "AMF")
            # IMPORTANT: click the 'amf' list item (lowercase in UI) to reveal Choose File control
            click_nf_entry(driver, "amf")
            # now upload; upload function has robust waits
            upload_config_file(driver, file_path)
            click_import(driver)
            click_apply(driver)
            confirm_popup(driver)
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
