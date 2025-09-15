from selenium import webdriver
from selenium.webdriver.chrome.options import Options
from selenium.webdriver.common.by import By
from selenium.webdriver.support.ui import WebDriverWait
from selenium.webdriver.support import expected_conditions as EC
import time, os, re

# EMS credentials and config path
url = "https://172.27.28.193.nip.io/ems/login"
username = "root"
password = "root123"
config_dir = "config_files"

# Setup Chrome options for Jenkins
options = Options()
options.add_argument("--headless=new")
options.add_argument("--no-sandbox")
options.add_argument("--disable-dev-shm-usage")

# Start Chrome WebDriver
driver = webdriver.Chrome(options=options)

# Utility Functions
def click_element_by_text(text, timeout=15):
    xpath = f"//div[contains(text(), '{text}')]"
    driver.save_screenshot("before_click_configure.png")
    WebDriverWait(driver, timeout).until(
        EC.element_to_be_clickable((By.XPATH, xpath))
    ).click()

def upload_config_file(file_path):
    file_input = WebDriverWait(driver, 10).until(
        EC.presence_of_element_located((By.XPATH, "//input[@type='file']"))
    )
    file_input.send_keys(file_path)

def click_button_by_text(text, timeout=10):
    xpath = f"//button[contains(text(), '{text}')]"
    WebDriverWait(driver, timeout).until(
        EC.element_to_be_clickable((By.XPATH, xpath))
    ).click()

# Start automation
driver.get(url)
time.sleep(2)

# Login
WebDriverWait(driver, 15).until(
    EC.presence_of_element_located((By.XPATH, "//input[@placeholder='Enter your username']"))
)
driver.find_element(By.XPATH, "//input[@placeholder='Enter your username']").send_keys(username)
driver.find_element(By.XPATH, "//input[@placeholder='Enter your password']").send_keys(password)
driver.find_element(By.XPATH, "//button[contains(text(),'Login')]").click()
time.sleep(3)

# Click through GUI tabs
click_element_by_text("Configure")
click_element_by_text("AMF")
click_element_by_text("Add")
click_element_by_text("amf")

# Find the AMF config file
amf_file = None
for file in os.listdir(config_dir):
    if re.search(r"(amf-function-.*_amf\.json|.*_amf\.json|amf\.json)$", file):
        amf_file = os.path.abspath(os.path.join(config_dir, file))
        break

if not amf_file:
    driver.quit()
    raise FileNotFoundError("No AMF config file found in config_files directory.")

# Upload and apply configuration
upload_config_file(amf_file)
click_button_by_text("Import")
click_button_by_text("Apply")
click_button_by_text("OK")

driver.quit()
