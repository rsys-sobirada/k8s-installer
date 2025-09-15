#!/usr/bin/env python3
# scripts/gui_upload.py
# AMF-only GUI upload automation (robust)
#
# Usage: CONFIG_DIR=/absolute/or/relative/path ./venv/bin/python scripts/gui_upload.py
# If CONFIG_DIR not set, defaults to "config_files" relative to current working directory.

from selenium import webdriver
from selenium.webdriver.firefox.options import Options
from selenium.webdriver.common.by import By
from selenium.webdriver.support.ui import WebDriverWait
from selenium.webdriver.support import expected_conditions as EC
import time, os, traceback

# -------- Configurable variables --------
url = "https://172.27.28.193.nip.io/ems/login"
username = "root"
password = "root123"

# read config dir from env or fallback to relative path
config_dir = os.environ.get("CONFIG_DIR", "config_files")

# debug artifacts
debug_dir = "debug_screenshots"
os.makedirs(debug_dir, exist_ok=True)

# Only AMF mapping (AMF-only run)
suffix_tab_map = {"_amf": "AMF"}

# -------- WebDriver setup --------
options = Options()
options.add_argument("--headless")
options.add_argument("--no-sandbox")
options.add_argument("--disable-dev-shm-usage")
options.accept_insecure_certs = True

driver = webdriver.Firefox(options=options)

# -------- Helpers for debugging --------
def save_debug(name):
    """Save screenshot into debug_dir with a timestamped filename."""
    path = os.path.join(debug_dir, f"{int(time.time())}_{name}.png")
    try:
        driver.save_screenshot(path)
        print(f"Saved screenshot: {path}")
    except Exception as e:
        print(f"Failed to save screenshot {path}: {e}")

def _save_page_source(name):
    """Save current page_source to an HTML file for inspection."""
    path = os.path.join(debug_dir, f"{int(time.time())}_{name}.html")
    try:
        with open(path, "w", encoding="utf-8") as fh:
            fh.write(driver.page_source)
        print(f"Saved page source: {path}")
    except Exception as e:
        print(f"Failed to save page source {path}: {e}")

# -------- Robust element lookup (text/attributes/iframes) --------
def find_element_by_text_any(tag_text, timeout=6):
    """
    Robust search for an element containing tag_text (case-insensitive).
    Strategies:
      1) case-insensitive XPath on text()
      2) iterate visible elements and match .text
      3) check common attributes (title, aria-label, data-*, alt, id, class, name)
      4) scan inside iframes
    Returns a WebElement if found, otherwise raises Exception and saves page source.
    """
    lower_text = tag_text.lower()
    xpaths = [
        f"//*[contains(translate(normalize-space(.), 'ABCDEFGHIJKLMNOPQRSTUVWXYZ', 'abcdefghijklmnopqrstuvwxyz'), '{lower_text}')]",
        f"//*[contains(translate(text(), 'ABCDEFGHIJKLMNOPQRSTUVWXYZ', 'abcdefghijklmnopqrstuvwxyz'), '{lower_text}')]",
    ]

    # 1) try XPath quickly
    for xp in xpaths:
        try:
            elem = WebDriverWait(driver, timeout).until(
                EC.presence_of_element_located((By.XPATH, xp))
            )
            return elem
        except Exception:
            pass

    # 2) scan many elements and check .text
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

    # 3) check attributes on all elements
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
            print(f"Found {len(iframes)} iframe(s); scanning inside them for '{tag_text}'")
        for idx, fr in enumerate(iframes):
            try:
                driver.switch_to.frame(fr)
                # quick xpath inside frame
                for xp in xpaths:
                    try:
                        elem = WebDriverWait(driver, 1).until(
                            EC.presence_of_element_located((By.XPATH, xp))
                        )
                        driver.switch_to.default_content()
                        return elem
                    except Exception:
                        pass
                # attribute scan inside frame
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

    # not found: save page source for debugging and raise
    _save_page_source(f"no_elem_{tag_text}")
    raise Exception(f"Element containing text '{tag_text}' not found using candidate strategies.")

# -------- Click helpers --------
def click_element_via_js(elem):
    """Scroll element into view and click via JS for headless reliability."""
    try:
        driver.execute_script("arguments[0].scrollIntoView({block:'center', inline:'center'});", elem)
        driver.execute_script("arguments[0].click();", elem)
    except Exception as e:
        raise

def open_configure_menu():
    """
    Click the 'Configure' entry in the left sidebar so NF icons become visible.
    Tries several strategies (text, aria-label, title, known sidebar container).
    """
    print("Attempting to open 'Configure' menu...")
    # Common XPaths to find sidebar Configure entry (case-insensitive)
    candidate_xps = [
        "//nav//a//*[contains(translate(normalize-space(.), 'ABCDEFGHIJKLMNOPQRSTUVWXYZ','abcdefghijklmnopqrstuvwxyz'), 'configure')]",
        "//a[contains(translate(normalize-space(.), 'ABCDEFGHIJKLMNOPQRSTUVWXYZ','abcdefghijklmnopqrstuvwxyz'), 'configure')]",
        "//*[contains(translate(normalize-space(.), 'ABCDEFGHIJKLMNOPQRSTUVWXYZ','abcdefghijklmnopqrstuvwxyz'), 'configure')]",
        # try elements with aria-label/title containing 'Configure'
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

    # fallback: search by visible text
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
    """
    Open Configure first (if needed) then find and click the NF icon/tab (AMF/SMF/UPF).
    """
    try:
        # Ensure Configure is open so NF icons are present
        try:
            open_configure_menu()
        except Exception:
            # If configure cannot be opened, continue to attempt to find NF (may already be visible)
            print("Proceeding to find NF tab even though Configure couldn’t be opened (maybe already visible).")

        print(f"Looking for NF tab '{nf_name}'")
        elem = find_element_by_text_any(nf_name, timeout=6)

        # scroll and try to click
        try:
            driver.execute_script("arguments[0].scrollIntoView({block:'center'});", elem)
            time.sleep(0.4)
        except Exception:
            pass

        try:
            elem.click()
            time.sleep(0.6)
        except Exception:
            # JS fallback
            try:
                driver.execute_script("arguments[0].click();", elem)
                time.sleep(0.6)
            except Exception as e2:
                print(f"Both normal click and JS click failed for '{nf_name}': {e2}")
                _save_page_source(f"click_failed_{nf_name}")
                raise
        print(f"Clicked NF tab '{nf_name}'")
    except Exception as e:
        _save_page_source(f"click_lookup_failed_{nf_name}")
        print(f"Error clicking NF tab '{nf_name}': {e}")
        raise

def click_add_button(driver, nf_name):
    """
    Click an 'Add' button associated with the NF. Tries button text 'Add' first.
    """
    try:
        candidate_xps = [
            "//button[contains(translate(normalize-space(.), 'ABCDEFGHIJKLMNOPQRSTUVWXYZ','abcdefghijklmnopqrstuvwxyz'), 'add')]",
            "//*[contains(translate(normalize-space(.), 'ABCDEFGHIJKLMNOPQRSTUVWXYZ','abcdefghijklmnopqrstuvwxyz'), 'add')]"
        ]
        for xp in candidate_xps:
            try:
                btn = WebDriverWait(driver, 6).until(EC.element_to_be_clickable((By.XPATH, xp)))
                try:
                    btn.click()
                except Exception:
                    driver.execute_script("arguments[0].click();", btn)
                time.sleep(0.6)
                print("Clicked Add button via XPath:", xp)
                return
            except Exception:
                continue

        # last resort: find elements with '+' icon or role='button' near nf area
        raise Exception("Add button not found by candidate XPaths.")
    except Exception as e:
        _save_page_source("add_button_not_found")
        print(f"Error clicking Add button for '{nf_name}': {e}")
        raise

def upload_config_file(driver, file_path):
    """
    Locate file input and send the file path.
    Makes hidden input visible if needed.
    """
    try:
        file_input = WebDriverWait(driver, 10).until(
            EC.presence_of_element_located((By.XPATH, "//input[@type='file' or contains(@type,'file')]"))
        )
        # Unhide if hidden
        try:
            driver.execute_script("arguments[0].style.display='block'; arguments[0].style.visibility='visible';", file_input)
        except Exception:
            pass
        file_input.send_keys(file_path)
        time.sleep(0.6)
        print(f"Provided file path to upload input: {file_path}")
    except Exception as e:
        _save_page_source("file_input_error")
        print(f"Error uploading file '{file_path}': {e}")
        raise

def click_import(driver):
    try:
        btn = WebDriverWait(driver, 12).until(
            EC.element_to_be_clickable((By.XPATH, "//button[contains(translate(normalize-space(.), 'ABCDEFGHIJKLMNOPQRSTUVWXYZ','abcdefghijklmnopqrstuvwxyz'), 'import')]"))
        )
        try:
            btn.click()
        except Exception:
            driver.execute_script("arguments[0].click();", btn)
        time.sleep(0.6)
        print("Clicked Import")
    except Exception as e:
        _save_page_source("import_button_error")
        print("Error clicking Import:", e)
        raise

def click_apply(driver):
    try:
        btn = WebDriverWait(driver, 12).until(
            EC.element_to_be_clickable((By.XPATH, "//button[contains(translate(normalize-space(.), 'ABCDEFGHIJKLMNOPQRSTUVWXYZ','abcdefghijklmnopqrstuvwxyz'), 'apply')]"))
        )
        try:
            btn.click()
        except Exception:
            driver.execute_script("arguments[0].click();", btn)
        time.sleep(0.6)
        print("Clicked Apply")
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
        # popup might not appear; that's fine
        print("No confirmation popup found (or confirmation click failed)")

# -------- Main script flow --------
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
        # Try a few locators for username
        try:
            driver.find_element(By.XPATH, "//input[@placeholder='Enter your username']").send_keys(username)
        except Exception:
            try:
                driver.find_element(By.XPATH, "//input[@name='username']").send_keys(username)
            except Exception:
                driver.find_element(By.XPATH, "//input[@id='username']").send_keys(username)

        # password field
        try:
            driver.find_element(By.XPATH, "//input[@placeholder='Enter your password']").send_keys(password)
        except Exception:
            try:
                driver.find_element(By.XPATH, "//input[@name='password']").send_keys(password)
            except Exception:
                driver.find_element(By.XPATH, "//input[@id='password']").send_keys(password)

        # click login button (several options)
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
            # fallback: press Enter on password field
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

    # Wait a short while for UI to stabilize
    try:
        WebDriverWait(driver, 12).until(
            EC.presence_of_element_located((By.XPATH, "//*[contains(@class,'main') or contains(@id,'app') or contains(@role,'main') or //div[@id='root']]"))
        )
    except Exception:
        # not fatal
        pass

    # Process AMF-only files
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
            click_nf_tab(driver, "AMF")
            click_add_button(driver, "AMF")
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
            # continue to next file (if any)
            continue

    print("AMF-only run finished.")
finally:
    try:
        driver.quit()
    except Exception:
        pass
