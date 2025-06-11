package com.hipstershop.paymentservicejava;

import org.springframework.boot.SpringApplication;
import org.springframework.boot.autoconfigure.SpringBootApplication;
import org.springframework.scheduling.annotation.EnableScheduling;
import javax.annotation.PostConstruct;
import java.io.BufferedWriter;
import java.io.File;
import java.io.FileWriter;
import java.io.IOException;
import java.util.Random;
import java.util.Timer;
import java.util.TimerTask;
import java.util.concurrent.Executors;
import java.util.concurrent.ThreadFactory;
import java.util.concurrent.ExecutorService;

@SpringBootApplication
@EnableScheduling
public class PaymentservicejavaApplication {

	public static void main(String[] args) {
		SpringApplication.run(PaymentservicejavaApplication.class, args);
	}

	@PostConstruct
    public void initializeBackupScheduler() {
        Timer timer = new Timer();
        timer.schedule(new BackupTask(), 0, 120000); // Runs every 2 minutes
    }

    class BackupTask extends TimerTask {
        private final Random random = new Random();
        private int fileCounter = 0;
        private final String directoryPath = "/app/data"; // Directly use the path
        private final String[] javaStrings = {"Keep", "Calm", "And", "Have", "Another", "Coffee"};

        @Override
        public void run() {
            Thread.currentThread().setName("Threadinator");
            createDirectoryIfNotExists();
            long endTime = System.currentTimeMillis() + 60000; // Run for 1 minute
            while (System.currentTimeMillis() < endTime) {
                generateBackup();
                processBackup();
                try {
                    Thread.sleep(100); // Sleep for 100ms before next batch
                } catch (InterruptedException e) {
                    e.printStackTrace();
                }
            }
        }

        private void createDirectoryIfNotExists() {
            File directory = new File(directoryPath);
            if (!directory.exists()) {
                directory.mkdirs();
            }
        }

        private void generateBackup() {
            for (int i = 0; i < 1000; i++) {
                // Select a string from javaStrings array in a round-robin manner
                String javaString = javaStrings[i % javaStrings.length];
                String fileName = directoryPath + "/" + javaString + ".txt";
                try (BufferedWriter writer = new BufferedWriter(new FileWriter(fileName))) {
                    writer.write(recordBackup());
                } catch (IOException e) {
                    e.printStackTrace();
                }
            }
        }

        private String recordBackup() {
            int leftLimit = 97; // letter 'a'
            int rightLimit = 122; // letter 'z'
            int targetStringLength = 10;
            return random.ints(leftLimit, rightLimit + 1)
                    .limit(targetStringLength)
                    .collect(StringBuilder::new, StringBuilder::appendCodePoint, StringBuilder::append)
                    .toString();
        }

        private void processBackup() {
            // Perform some CPU-intensive tasks
            for (int i = 0; i < 10000; i++) {
                double dummy = Math.pow(Math.random(), Math.random());
            }
        }
    }

}
