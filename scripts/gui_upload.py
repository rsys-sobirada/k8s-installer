# scripts/gui_upload.py (AMF-only version - drop into your repo)
from selenium import webdriver
from selenium.webdriver.firefox.options import Options
from selenium.webdriver.common.by import By
from selenium.webdriver.support.ui import WebDriverWait
from selenium.webdriver.support import expected_conditions as EC
import time, os, traceback

# Config
url = "https://172.27.28.193.nip.io/ems/login"
username = "root"
password = "root123"
# read config dir from env if provided, else default to workspace relative folder
config_dir = os.environ.get("CONFIG_DIR", "config_files")
debug_dir = "debug_screenshots"
os.makedirs(debug_dir, exist_ok=True)

# Only AMF mapping (AMF-only run)
suffix_tab_map = {
    "_amf": "AMF"
}

# Firefox options
options = Options()
options.add_argument("--headless")
options.add_argument("--no-sandbox")
options.add_argument("--disable-dev-shm-usage")
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
    driver.execute_script("arguments[0].click();", elem)

def find_element_by_text_any(tag_text, timeout=10):
    lower_text = tag_text.lower()
    xpaths = [
        f"//*[contains(translate(normalize-space(.), 'ABCDEFGHIJKLMNOPQRSTUVWXYZ', 'abcdefghijklmnopqrstuvwxyz'), '{lower_text}')]",
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
    raise Exception(f"Element containing text '{tag_text}' not found using candidate XPaths.")

def click_nf_tab(driver, nf_name):
    print(f"Looking for NF tab '{nf_name}'")
    elem = find_element_by_text_any(nf_name, timeout=15)
    click_element_via_js(elem)
    time.sleep(1)

def click_add_button(driver, nf_name):
    # simple 'Add' click (may need refinement for your UI)
    try:
        btn = WebDriverWait(driver, 8).until(
            EC.element_to_be_clickable((By.XPATH, "//button[contains(translate(normalize-space(.), 'ABCDEFGHIJKLMNOPQRSTUVWXYZ', 'abcdefghijklmnopqrstuvwxyz'), 'add')]"))
        )
        click_element_via_js(btn)
        time.sleep(0.6)
    except Exception as e:
        raise

def upload_config_file(driver, file_path):
    file_input = WebDriverWait(driver, 10).until(
        EC.presence_of_element_located((By.XPATH, "//input[@type='file']"))
    )
    driver.execute_script("arguments[0].style.display='block'; arguments[0].style.visibility='visible';", file_input)
    file_input.send_keys(file_path)
    time.sleep(0.5)

def click_import(driver):
    btn = WebDriverWait(driver, 10).until(
        EC.element_to_be_clickable((By.XPATH, "//button[contains(translate(normalize-space(.), 'ABCDEFGHIJKLMNOPQRSTUVWXYZ', 'abcdefghijklmnopqrstuvwxyz'), 'import')]"))
    )
    click_element_via_js(btn)
    time.sleep(0.6)

def click_apply(driver):
    btn = WebDriverWait(driver, 10).until(
        EC.element_to_be_clickable((By.XPATH, "//button[contains(translate(normalize-space(.), 'ABCDEFGHIJKLMNOPQRSTUVWXYZ', 'abcdefghijklmnopqrstuvwxyz'), 'apply')]"))
    )
    click_element_via_js(btn)
    time.sleep(0.6)

def confirm_popup(driver):
    try:
        btn = WebDriverWait(driver, 8).until(
            EC.element_to_be_clickable((By.XPATH, "//button[contains(translate(normalize-space(.), 'ABCDEFGHIJKLMNOPQRSTUVWXYZ', 'abcdefghijklmnopqrstuvwxyz'), 'ok') or contains(translate(normalize-space(.), 'ABCDEFGHIJKLMNOPQRSTUVWXYZ', 'abcdefghijklmnopqrstuvwxyz'), 'yes')]"))
        )
        click_element_via_js(btn)
    except Exception:
        # optional: no popup present
        pass

# start
print("Using config_dir:", os.path.abspath(config_dir))
driver.get(url)
time.sleep(2)
save_debug("login_page")

# login (robust)
try:
    WebDriverWait(driver, 20).until(
        EC.presence_of_element_located((By.XPATH, "//input[@placeholder='Enter your username' or @name='username' or @id='username']"))
    )
    # fill fields (try multiple locators)
    try:
        driver.find_element(By.XPATH, "//input[@placeholder='Enter your username']").send_keys(username)
    except:
        try:
            driver.find_element(By.XPATH, "//input[@name='username']").send_keys(username)
        except:
            driver.find_element(By.XPATH, "//input[@id='username']").send_keys(username)
    try:
        driver.find_element(By.XPATH, "//input[@placeholder='Enter your password']").send_keys(password)
    except:
        try:
            driver.find_element(By.XPATH, "//input[@name='password']").send_keys(password)
        except:
            driver.find_element(By.XPATH, "//input[@id='password']").send_keys(password)
    # click login
    try:
        login_btn = WebDriverWait(driver, 8).until(
            EC.element_to_be_clickable((By.XPATH, "//button[contains(translate(normalize-space(.), 'ABCDEFGHIJKLMNOPQRSTUVWXYZ', 'abcdefghijklmnopqrstuvwxyz'), 'login')]"))
        )
        click_element_via_js(login_btn)
    except Exception:
        driver.find_element(By.XPATH, "//input[@type='password']").send_keys("\n")
    time.sleep(3)
    save_debug("after_login")
except Exception as e:
    print("Login failed:", e)
    save_debug("login_failed")
    driver.quit()
    raise SystemExit(1)

# process only AMF files
print("Scanning config_dir for AMF files...")
for file in os.listdir(config_dir):
    print(f"Found file: {file}")
    if not file.lower().endswith("_amf.json"):
        print(f"Skipping (not AMF): {file}")
        continue

    file_path = os.path.abspath(os.path.join(config_dir, file))
    print(f"Processing AMF file: {file_path}")

    try:
        # save screenshot before attempting to click the AMF tab
        save_debug(f"before_click_amf_{file}")
        click_nf_tab(driver, "AMF")   # AMF tab click
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

driver.quit()
print("AMF-only run finished.")
