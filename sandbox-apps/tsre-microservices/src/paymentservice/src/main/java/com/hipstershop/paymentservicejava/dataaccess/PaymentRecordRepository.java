package com.hipstershop.paymentservicejava.dataaccess;

import org.springframework.data.repository.CrudRepository;
import org.springframework.stereotype.Repository;

import com.hipstershop.paymentservicejava.model.PaymentRecord;

@Repository
public interface PaymentRecordRepository extends CrudRepository<PaymentRecord, Long>{

}
