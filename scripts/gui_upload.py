# scripts/gui_upload.py (updated)
from selenium import webdriver
from selenium.webdriver.firefox.options import Options
from selenium.webdriver.common.by import By
from selenium.webdriver.support.ui import WebDriverWait
from selenium.webdriver.support import expected_conditions as EC
import time, os, traceback

# EMS credentials and config path
url = "https://172.27.28.193.nip.io/ems/login"
username = "root"
password = "root123"
config_dir = "config_files"
debug_dir = "debug_screenshots"

os.makedirs(debug_dir, exist_ok=True)

# Mapping suffix to tab name
suffix_tab_map = {
    "_amf": "AMF",
    "_smf": "SMF",
    "_upf": "UPF"
}

# Setup Firefox options for Jenkins
options = Options()
options.add_argument("--headless")
options.add_argument("--no-sandbox")
options.add_argument("--disable-dev-shm-usage")
# allow insecure certs for local IP (if needed)
options.accept_insecure_certs = True

driver = webdriver.Firefox(options=options)

def save_debug(name):
    path = os.path.join(debug_dir, f"{int(time.time())}_{name}.png")
    try:
        driver.save_screenshot(path)
        print(f"Saved screenshot: {path}")
    except Exception as e:
        print(f"Failed to save screenshot {path}: {e}")

def click_element_via_js(elem):
    driver.execute_script("arguments[0].scrollIntoView({block:'center', inline:'center'});", elem)
    # use JS click for reliability in headless
    driver.execute_script("arguments[0].click();", elem)

def find_element_by_text_any(tag_text, timeout=15):
    """
    Find element containing tag_text (case-insensitive) in its text content.
    Returns the WebElement or raises TimeoutException.
    """
    # Use translate to do case-insensitive match (convert both to lowercase)
    lower_text = tag_text.lower()
    xpaths = [
        # match any element whose normalized text contains the nf name (case-insensitive)
        f"//*[contains(translate(normalize-space(.), 'ABCDEFGHIJKLMNOPQRSTUVWXYZ', 'abcdefghijklmnopqrstuvwxyz'), '{lower_text}')]",
        # fallback: element whose text node contains (keeps spaces)
        f"//*[contains(translate(text(), 'ABCDEFGHIJKLMNOPQRSTUVWXYZ', 'abcdefghijklmnopqrstuvwxyz'), '{lower_text}')]",
    ]
    for xp in xpaths:
        try:
            elem = WebDriverWait(driver, timeout).until(
                EC.presence_of_element_located((By.XPATH, xp))
            )
            return elem
        except Exception:
            continue
    # if not found, throw the last exception by explicit timeout
    # this will raise TimeoutException to caller
    raise Exception(f"Element containing text '{tag_text}' not found using candidate XPaths.")

def click_nf_tab(driver, nf_name):
    """
    Robustly click the NF tab by searching any element containing the nf_name (case-insensitive).
    """
    try:
        print(f"Looking for NF tab '{nf_name}'")
        elem = find_element_by_text_any(nf_name, timeout=15)
        click_element_via_js(elem)
        time.sleep(1)  # slight pause to allow UI to react
    except Exception as e:
        save_debug(f"{nf_name}_tab_not_found")
        print(f"Error clicking NF tab '{nf_name}': {e}")
        raise

def click_add_button(driver, nf_name):
    """
    Click an 'Add' button related to the NF. Many UIs use simple 'Add' button.
    We try multiple strategies:
      - button whose text contains 'add' (case-insensitive)
      - button containing both 'add' and nf_name nearby
    """
    try:
        print(f"Looking for Add button for '{nf_name}'")
        # 1) Find a button element with 'add' in it
        add_btn_xpath_primary = "//button[contains(translate(normalize-space(.), 'ABCDEFGHIJKLMNOPQRSTUVWXYZ', 'abcdefghijklmnopqrstuvwxyz'), 'add')]"
        # 2) Fallback: any element whose text contains 'add' (not strictly a button)
        add_btn_xpath_fallback = "//*[contains(translate(normalize-space(.), 'ABCDEFGHIJKLMNOPQRSTUVWXYZ', 'abcdefghijklmnopqrstuvwxyz'), 'add')]"
        for xp in (add_btn_xpath_primary, add_btn_xpath_fallback):
            try:
                btn = WebDriverWait(driver, 8).until(EC.element_to_be_clickable((By.XPATH, xp)))
                click_element_via_js(btn)
                time.sleep(0.6)
                return
            except Exception:
                continue

        # 3) last resort: try to locate an 'Add <nf_name>' literal
        combined_xp = f"//button[contains(translate(normalize-space(.), 'ABCDEFGHIJKLMNOPQRSTUVWXYZ', 'abcdefghijklmnopqrstuvwxyz'), 'add') and contains(translate(normalize-space(.), 'ABCDEFGHIJKLMNOPQRSTUVWXYZ', 'abcdefghijklmnopqrstuvwxyz'), '{nf_name.lower()}')]"
        btn = WebDriverWait(driver, 5).until(EC.element_to_be_clickable((By.XPATH, combined_xp)))
        click_element_via_js(btn)
        time.sleep(0.6)
    except Exception as e:
        save_debug(f"{nf_name}_add_button_not_found")
        print(f"Error clicking Add button for '{nf_name}': {e}")
        raise

def upload_config_file(driver, file_path):
    try:
        print(f"Uploading file: {file_path}")
        file_input = WebDriverWait(driver, 10).until(
            EC.presence_of_element_located((By.XPATH, "//input[@type='file']"))
        )
        # if input is hidden, un-hide it so send_keys works reliably
        driver.execute_script("arguments[0].style.display='block'; arguments[0].style.visibility='visible'; arguments[0].style.height='1px';", file_input)
        file_input.send_keys(file_path)
        time.sleep(0.5)
    except Exception as e:
        save_debug("file_input_error")
        print(f"Error uploading file '{file_path}': {e}")
        raise

def click_import(driver):
    try:
        btn = WebDriverWait(driver, 12).until(
            EC.element_to_be_clickable((By.XPATH, "//button[contains(translate(normalize-space(.), 'ABCDEFGHIJKLMNOPQRSTUVWXYZ', 'abcdefghijklmnopqrstuvwxyz'), 'import')]"))
        )
        click_element_via_js(btn)
        time.sleep(0.6)
    except Exception as e:
        save_debug("import_button_error")
        print(f"Error clicking Import: {e}")
        raise

def click_apply(driver):
    try:
        btn = WebDriverWait(driver, 12).until(
            EC.element_to_be_clickable((By.XPATH, "//button[contains(translate(normalize-space(.), 'ABCDEFGHIJKLMNOPQRSTUVWXYZ', 'abcdefghijklmnopqrstuvwxyz'), 'apply')]"))
        )
        click_element_via_js(btn)
        time.sleep(0.6)
    except Exception as e:
        save_debug("apply_button_error")
        print(f"Error clicking Apply: {e}")
        raise

def confirm_popup(driver):
    try:
        btn = WebDriverWait(driver, 12).until(
            EC.element_to_be_clickable((By.XPATH, "//button[contains(translate(normalize-space(.), 'ABCDEFGHIJKLMNOPQRSTUVWXYZ', 'abcdefghijklmnopqrstuvwxyz'), 'ok') or contains(translate(normalize-space(.), 'ABCDEFGHIJKLMNOPQRSTUVWXYZ', 'abcdefghijklmnopqrstuvwxyz'), 'yes')]"))
        )
        click_element_via_js(btn)
        time.sleep(0.6)
    except Exception as e:
        # popup might be absent sometimes; just log and continue
        save_debug("confirm_popup_missing_or_error")
        print(f"Confirm popup not found or error: {e}")

# Start automation
driver.get(url)
time.sleep(2)
save_debug("login_page_debug")

# Login
try:
    WebDriverWait(driver, 20).until(
        EC.presence_of_element_located((By.XPATH, "//input[@placeholder='Enter your username' or @name='username' or @id='username']"))
    )
    # try multiple locators to be robust
    try:
        driver.find_element(By.XPATH, "//input[@placeholder='Enter your username']").send_keys(username)
    except Exception:
        try:
            driver.find_element(By.XPATH, "//input[@name='username']").send_keys(username)
        except Exception:
            driver.find_element(By.XPATH, "//input[@id='username']").send_keys(username)

    try:
        driver.find_element(By.XPATH, "//input[@placeholder='Enter your password']").send_keys(password)
    except Exception:
        try:
            driver.find_element(By.XPATH, "//input[@name='password']").send_keys(password)
        except Exception:
            driver.find_element(By.XPATH, "//input[@id='password']").send_keys(password)

    # click login button - try multiple candidate buttons
    login_btn_xps = [
        "//button[contains(translate(normalize-space(.), 'ABCDEFGHIJKLMNOPQRSTUVWXYZ', 'abcdefghijklmnopqrstuvwxyz'), 'login')]",
        "//input[@type='submit' and (contains(translate(@value, 'ABCDEFGHIJKLMNOPQRSTUVWXYZ', 'abcdefghijklmnopqrstuvwxyz'),'login'))]",
    ]
    clicked = False
    for xp in login_btn_xps:
        try:
            login_btn = WebDriverWait(driver, 8).until(EC.element_to_be_clickable((By.XPATH, xp)))
            click_element_via_js(login_btn)
            clicked = True
            break
        except Exception:
            continue
    if not clicked:
        print("Login button not found by standard XPaths; trying enter key on password field.")
        driver.find_element(By.XPATH, "//input[@type='password']").send_keys("\n")

    time.sleep(3)
    save_debug("after_login")
except Exception as e:
    save_debug("login_failed")
    print("Login failed:", e)
    traceback.print_exc()
    driver.quit()
    raise SystemExit(1)

# Wait for main UI to load - try common containers
try:
    WebDriverWait(driver, 20).until(
        EC.presence_of_element_located((By.XPATH, "//*[contains(@class,'main') or contains(@id,'app') or contains(@role,'main') or //div[@id='root']]"))
    )
except Exception:
    # not fatal — we continue but add screenshot
    save_debug("main_ui_not_detected")
    print("Warning: main UI container not detected; continuing anyway.")

# Loop through config files with logging
print("Scanning config_files directory...")
for file in os.listdir(config_dir):
    print(f"Checking file: {file}")
    # skip non-json files
    if not file.lower().endswith(".json"):
        print(f"Skipping non-json file: {file}")
        continue

    matched = False
    for suffix, nf_name in suffix_tab_map.items():
        expected_suffix = suffix + ".json"
        if file.endswith(expected_suffix):
            matched = True
            print(f"Matched file '{file}' with suffix '{suffix}' → NF tab: {nf_name}")
            file_path = os.path.abspath(os.path.join(config_dir, file))
            try:
                click_nf_tab(driver, nf_name)
                click_add_button(driver, nf_name)
                upload_config_file(driver, file_path)
                click_import(driver)
                click_apply(driver)
                confirm_popup(driver)
                print(f"Upload sequence completed for {file}")
                save_debug(f"{file}_completed")
            except Exception as e:
                # log and continue with next file (do not fail entire run)
                print(f"Failed to upload {file}: {e}")
                traceback.print_exc()
                save_debug(f"{file}_error")
            break

    if not matched:
        print(f"No matching NF suffix for {file} — skipping.")

driver.quit()
print("Script finished.")
