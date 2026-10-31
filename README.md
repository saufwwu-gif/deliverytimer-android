地圖功能及車輛維修功能已關閉分頁 暫時停止開發

功能說明請看海報 如對無障礙及錄影功能有疑問可全部關閉使用內建截圖

匯入uber雙週補償明細對比

及pdf轉csv之流程請參考說明海報 

gemini提示詞pdf轉csv放在最下面(海報最下方)
<img width="594" height="841" alt="《薪水計時》App 封測功能指南 (A4 宣傳頁)" src="https://github.com/user-attachments/assets/102b77a1-4e3d-4491-96b3-476133bfa547" />
<img width="594" height="841" alt="2" src="https://github.com/user-attachments/assets/8042c074-710a-415c-8176-145f644c2f23" />
<img width="594" height="841" alt="3" src="https://github.com/user-attachments/assets/bc03e96b-4e00-4810-979e-803f0cf3cdf8" />
<img width="1080" height="1350" alt="Threads_Uber對帳教學_卡片01" src="https://github.com/user-attachments/assets/e573f676-d3c0-4fea-89ec-6187d14ab51a" />
<img width="1080" height="1350" alt="Threads_Uber對帳教學_卡片02" src="https://github.com/user-attachments/assets/a4cf8840-bd8d-45ff-9008-59ec36f742cc" />
<img width="1080" height="1350" alt="Threads_Uber對帳教學_卡片03" src="https://github.com/user-attachments/assets/b5a42eea-ef16-4a5e-8c36-8876ef08b1af" />
<img width="594" height="841" alt="Uber每週帳單明細_教學示範版(虛擬數據)" src="https://github.com/user-attachments/assets/3baef778-460e-4a65-9401-1a1bbd183106" />
<img width="594" height="841" alt="Uber每週帳單明細_教學示範版(虛擬數據)2" src="https://github.com/user-attachments/assets/0c4809b5-3a78-4bea-aa07-d6b0e5144bf6" />

請幫我將這份 Uber 每週帳單明細中的「行程詳細紀錄」表格，完整提取並轉換為標準 CSV 格式。要求如下：

1. 【第一欄：日期時間格式】
   務必完整包含年月日與時間，格式請使用「YYYY/MM/DD hh:mm AM/PM」（例如：2026/11/02 11:15 AM）或「YYYY-MM-DD HH:mm」。請勿只保留時間而省略年月日！

2. 【保留完整 6 個欄位】
   欄位順序請依序為：
   日期, 活動, 行程時間, 投入時間符合資格之基本行程費用, 最低添加保障方案, 您的總投入時間符合資格之基本行程費用

3. 【金額格式】
   金額請保留數字與小數點（例如 142.9 或 $142.9 皆可），第一行請務必加上欄位標題。

4. 【輸出格式】
   請直接輸出純 CSV 格式代碼區塊，不要額外輸出客套說明文字。
